"""Compare fresh improved/reference-compatible runs with durable SFC fixtures."""
import argparse
from contextlib import ExitStack
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from job_runtime import snapshot
from reference_fixtures import json_bytes

FIRST_EXPONENT = 10
LAST_EXPONENT = 32
FIXTURES = ROOT / 'test/reference-results/practrand-0.96.json'
CHUNK_BYTES = 1 << 20
HEADER = re.compile(r'^length=.*\(2\^(\d+) bytes\), time=')
ROW = re.compile(r'^  (.*?)\s+R[=<>]')
CORRECTED_FPF64 = re.compile(r'^(?:\[[^]]+\])*FPF/64:')


def report_rows(text):
    """Compare row content, preserving uniqueness while ignoring presentation order."""
    checkpoints = {}
    rows = None
    for line in text.splitlines():
        if (header := HEADER.match(line)) is not None:
            exponent = int(header[1])
            if exponent in checkpoints:
                raise ValueError(f'duplicate checkpoint 2^{exponent}')
            rows = {}
            checkpoints[exponent] = rows
        elif (match := ROW.match(line)) is not None:
            if rows is None:
                raise ValueError('result outside a checkpoint')
            name = match[1]
            if name in rows:
                raise ValueError(f'duplicate test name: {name}')
            rows[name] = line.rstrip()
        elif line.startswith('error:') or line.startswith('error reading'):
            raise ValueError(line)
    return checkpoints


def load_reference(path):
    reference = json.loads(path.read_bytes())
    if reference['format_version'] != 1:
        raise ValueError('unsupported concatenated reference format')
    records = reference['records']
    summary = records['summary.json']
    if summary.get('status') != 'accepted':
        raise ValueError('reference summary must be accepted')
    # Verify every retained checkpoint, including the span beyond routine tests.
    # Missing manifests, records, or hashes are errors, never an integrity opt-out.
    hashes = summary['checkpoint_sha256']
    checkpoints = {name for name in records if re.fullmatch(r'sfc(?:16|32|64)/2\^\d+\.json', name)}
    if not hashes or checkpoints != set(hashes):
        raise ValueError('reference checkpoints differ from the accepted manifest')
    for name, digest in hashes.items():
        if hashlib.sha256(json_bytes(records[name])).hexdigest() != digest:
            raise ValueError(f'accepted reference checksum differs: {name}')
    return records


def load_fixtures(records, generator, last):
    provenance = records['provenance.json']
    if (provenance['format_version'] != 1 or provenance['reference_version'] != '0.96' or
            provenance['generator_seed'] != {'low': 0, 'high': 0, 'initialization': 'original seed()'} or
            provenance['classification_seed'] != {'low': '0x9e3779b97f4a7c15', 'high': '0x0', 'scope': 'each C8 stream'} or
            provenance['classification_bit_consumption'] != 'all 64 bits, low byte first; one byte per classification' or
            provenance['battery'] != 'Expanded' or provenance['folding'] != 'extra'):
        raise ValueError('reference fixture configuration differs from the comparison contract')
    inputs = records['input-prefixes.json']
    if inputs['seed_low'] != 0 or inputs['seed_high'] != 0 or inputs['bytes'] != CHUNK_BYTES:
        raise ValueError('unexpected original input-prefix configuration')
    state = records[f'{generator}/run.json']
    expected = list(range(FIRST_EXPONENT, last + 1))
    if state['completed_exponents'][:len(expected)] != expected:
        retained = state['completed_exponents'][-1:]
        raise ValueError(f'{generator} reference lacks checkpoints through 2^{last}; '
                         f'last retained exponent: {retained}')
    reports = {}
    for exponent in expected:
        name = f'{generator}/2^{exponent}.json'
        record = records[name]
        parsed = report_rows(record['report'])
        names = [row['name'] for row in record['results']]
        if (record['exponent'] != exponent or record['bytes'] != 1 << exponent or
                list(parsed) != [exponent] or list(parsed[exponent]) != names or
                not names or len(names) != len(set(names))):
            raise ValueError(f'inconsistent reference fixture: {name}')
        reports[exponent] = parsed[exponent]
    return reports, inputs['cases'][generator]['sha256']


def differences(expected, actual):
    """Only corrected FPF/64 may change values and available subtests.

    Its independent kernel checks validate the corrected sampling. C8 is fully
    compared: both seeding and word consumption match the captured reference.
    Other accepted corrections concern upstream errors, not arbitrary finite
    values; missing or changed ordinary rows remain comparison failures.
    """
    messages = []
    if list(actual) != list(expected):
        messages.append(f'checkpoint sequence differs: {list(expected)} != {list(actual)}')
    for exponent in sorted(expected.keys() & actual.keys()):
        left = {k: v for k, v in expected[exponent].items() if not CORRECTED_FPF64.match(k)}
        right = {k: v for k, v in actual[exponent].items() if not CORRECTED_FPF64.match(k)}
        if left != right:
            messages.extend(difflib.unified_diff([left[k] for k in sorted(left)],
                                                [right[k] for k in sorted(right)],
                                                fromfile=f'original 2^{exponent}',
                                                tofile=f'rewrite 2^{exponent}', lineterm=''))
    return '\n'.join(messages)


def run_case(rewrite, generator, name, mode, last, expected, prefix_sha256, output):
    width = name.removeprefix('sfc')
    limit = 1 << last
    command = [str(rewrite), 'stdin' + width, '-te', '1', '-tf', '2', '-tlmin', '1K',
               '-tlmax', str(last), '-tlmaxonly', '-a', '-seed', '0']
    if mode == 'reference':
        command.append('--reference-compatible')
    producer_command = [str(generator), width, str(limit)]
    stem = output / f'{name}.{mode}'
    sent = 0
    digest, prefix = hashlib.sha256(), hashlib.sha256()
    input_error = False
    processes = []
    with ExitStack() as files:
        report_file = files.enter_context(Path(str(stem) + '.txt').open('wb'))
        error_file = files.enter_context(Path(str(stem) + '.stderr').open('wb'))
        producer_error = files.enter_context(Path(str(stem) + '.generator.stderr').open('wb'))
        try:
            tester = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=report_file, stderr=error_file)
            processes.append(tester)
            producer = subprocess.Popen(producer_command, stdout=subprocess.PIPE, stderr=producer_error)
            processes.append(producer)
            while sent < limit:
                data = producer.stdout.read(min(CHUNK_BYTES, limit - sent))
                if not data:
                    break
                digest.update(data)
                prefix.update(data[:max(0, CHUNK_BYTES - sent)])
                try:
                    tester.stdin.write(data)
                except BrokenPipeError:
                    input_error = True
                    break
                sent += len(data)
            try:
                tester.stdin.close()
            except BrokenPipeError:
                input_error = True
            # Reject a generator that produces more than the requested stream.
            extra = producer.stdout.read(1) if sent == limit else b''
            producer.stdout.close()
            codes = [tester.wait(), producer.wait()]
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                for stream in (process.stdin, process.stdout):
                    if stream is not None and not stream.closed:
                        try:
                            stream.close()
                        except BrokenPipeError:
                            pass
    report = Path(str(stem) + '.txt').read_text()
    errors = Path(str(stem) + '.stderr').read_text()
    generator_errors = Path(str(stem) + '.generator.stderr').read_text()
    try:
        difference = differences(expected, report_rows(report))
    except ValueError as error:
        difference = str(error)
    Path(str(stem) + '.diff').write_text(difference)
    # Short explicit runs still verify the complete 1 MiB generator prefix in
    # main(); their delivered prefix is shorter and has a different checksum.
    input_matches = sent < CHUNK_BYTES or prefix.hexdigest() == prefix_sha256
    mode_selected = ('results = reference-compatible (PractRand 0.96; documented corrections)' in report) == (mode == 'reference')
    passed = (codes == [0, 0] and sent == limit and not input_error and not extra and
              not errors and not generator_errors and input_matches and mode_selected and not difference)
    result = {'passed': passed, 'command': command, 'generator': producer_command,
              'exit_codes': codes, 'bytes_sent': sent, 'requested_bytes': limit,
              'input_error': input_error, 'input_sha256': digest.hexdigest(),
              'prefix_matches_original': input_matches, 'selected_mode_identified': mode_selected,
              'reports_match': not difference}
    Path(str(stem) + '.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'{"PASS" if passed else "FAIL"} {name} {mode}: {sent}/{limit} bytes', flush=True)
    if difference:
        print('\n'.join(difference.splitlines()[:20]), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rewrite', type=Path, default=ROOT / 'zig-out/bin/RNG_test')
    parser.add_argument('--fixtures', type=Path, default=FIXTURES)
    parser.add_argument('--output', type=Path, default=ROOT / '.work/fixture-comparison')
    parser.add_argument('--last-exponent', type=int, default=LAST_EXPONENT)
    options = parser.parse_args()
    if not FIRST_EXPONENT <= options.last_exponent <= 40:
        parser.error('--last-exponent must be between 10 and 40')
    try:
        records = load_reference(options.fixtures)
        fixtures = {name: load_fixtures(records, name, options.last_exponent)
                    for name in ('sfc16', 'sfc32', 'sfc64')}
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(f'durable reference fixtures unavailable or invalid: {error}; '
                     'choose a retained limit or capture a new reference explicitly; '
                     'the test target never regenerates baselines')
    options.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='runtime-', dir=options.output) as directory:
        generator = Path(directory) / 'sfc_stream'
        subprocess.run(['clang', '-O3', '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                        str(ROOT / 'test/sfc_stream.c'), '-o', str(generator)], check=True)
        paths, manifest = snapshot({'rewrite': options.rewrite}, directory)
        manifest['generator'] = {'source_sha256': hashlib.sha256((ROOT / 'test/sfc_stream.c').read_bytes()).hexdigest(),
                                 'sha256': hashlib.sha256(generator.read_bytes()).hexdigest()}
        (options.output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        results = {}
        for name, (expected, prefix_sha256) in fixtures.items():
            probe = subprocess.run([str(generator), name.removeprefix('sfc'), str(CHUNK_BYTES)],
                                   capture_output=True, check=True)
            if probe.stderr or hashlib.sha256(probe.stdout).hexdigest() != prefix_sha256:
                raise ValueError(f'{name} generator differs from captured original prefix')
            cases = {}
            for mode in ('reference', 'improved'):
                cases[mode] = run_case(paths['rewrite'], generator, name, mode,
                                       options.last_exponent, expected, prefix_sha256, options.output)
            if cases['reference']['input_sha256'] != cases['improved']['input_sha256']:
                raise ValueError('modes did not receive identical input')
            results[name] = cases
        (options.output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    return 0 if all(case['passed'] for modes in results.values() for case in modes.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
