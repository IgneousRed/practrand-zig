"""Stage original SFC checkpoints with the rewrite's fixed C8 seed.

Concatenate the completed records with tools/reference_fixtures.py before review.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

from job_runtime import retain_environment
from acquire_reference import ensure

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / '.work/reference-sfc-capture'
GENERATORS = ('sfc16', 'sfc32', 'sfc64')
FIRST_EXPONENT = 10
DEFAULT_LAST_EXPONENT = 38
C8_SEED = '0x9e3779b97f4a7c15'
MARKER = '@reference\t'
LENGTH = re.compile(r'^length=.*\(2\^(\d+) bytes\), time=\s*([\d.]+) seconds$')
RESULT = re.compile(r'^  (.*?)\s+R[=<>]')


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def publish(path, value):
    """Publish complete JSON without exposing a truncated checkpoint."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2, allow_nan=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def replace_once(data, old, new):
    if data.count(old) != 1:
        raise ValueError(f'expected exactly one upstream insertion point: {old!r}')
    return data.replace(old, new, 1)


def instrument(data):
    """Observe already-computed results without changing original decisions."""
    newline = b'\r\n' if b'\r\n' in data else b'\n'
    begin = r'''
    if (std::getenv("PRACTRAND_CAPTURE_VALUES")) {
        std::printf("@reference\tB\t%llu\t%lu\n", (unsigned long long)length, (unsigned long)results.size());
        for (std::size_t i = 0; i < results.size(); ++i) {
            const PractRand::TestResult &r = results[i];
            std::printf("@reference\tR\t%s\t%ld\t%.17g\t%.17g\t%.17g\t%.17g\t%.17g\n",
                r.name.c_str(), r.type, r.raw, r.processed, r.get_pvalue(), r.get_suspicion(), r.get_weight());
        }
    }
'''.replace('\n', newline.decode()).encode()
    end = r'''
    if (std::getenv("PRACTRAND_CAPTURE_VALUES")) {
        std::printf("@reference\tE\t%llu\n", (unsigned long long)length);
        std::fflush(stdout);
    }
'''.replace('\n', newline.decode()).encode()
    data = replace_once(data, b'\tdouble biggest_decimal_suspicion = 0;',
                        begin + b'\tdouble biggest_decimal_suspicion = 0;')
    return replace_once(data, b'\tstd::fflush(stdout);', b'\tstd::fflush(stdout);' + end)


def match_classification(data):
    """Keep original C8 counts, using the rewrite's seed and complete tie words."""
    data = replace_once(data, b'internal_rng.seed(known_good->raw64());',
                        b'(void)known_good->raw64(); internal_rng.seed(Uint64(0x9e3779b97f4a7c15ULL));')
    start = data.index(b'void PractRand::Tests::Transforms::classify128to8::test_blocks(')
    before, classification = data[:start], data[start:]
    newline = b'\r\n' if b'\r\n' in data else b'\n'
    # Every original input call contains whole 1 KiB blocks: 64 classifications
    # per block. Every call therefore ends on a complete 64-bit tie word.
    classification = replace_once(classification, b'\tlong i = 0;',
                                  b'\tUint64 rand = 0;' + newline + b'\tlong i = 0;')
    classification = replace_once(classification, b'\t\tUint64 rand = internal_rng.raw64();',
                                  b'\t\tif ((i & 15) == 0) rand = internal_rng.raw64();')
    return before + classification


def prepare(work):
    source = ensure(ROOT)
    frozen = work / 'source'
    shutil.copytree(source, frozen)
    originals = {str(p.relative_to(source)): sha256(p.read_bytes())
                 for p in sorted(source.rglob('*')) if p.is_file()}
    path = frozen / 'src/tests_core.cpp'
    original = path.read_bytes()
    modified = match_classification(original)
    path.write_bytes(modified)
    tool = frozen / 'tools/RNG_test.cpp'
    tool_original = tool.read_bytes()
    tool_modified = instrument(tool_original)
    tool.write_bytes(tool_modified)
    changes = {'src/tests_core.cpp': (original, modified),
               'tools/RNG_test.cpp': (tool_original, tool_modified)}
    patch = ''.join(''.join(difflib.unified_diff(
        before.decode().splitlines(keepends=True), after.decode().splitlines(keepends=True),
        fromfile='original/' + name, tofile='diagnostic/' + name))
        for name, (before, after) in changes.items())
    (work / 'diagnostic.patch').write_text(patch)
    driver = work / 'classification.cpp'
    driver.write_bytes((ROOT / 'test/reference_classification.cpp').read_bytes())
    command = [sys.executable, '-B', str(ROOT / 'tools/build_reference.py'), str(frozen),
               '--driver', str(driver),
               '--tools', '--output', str(work / 'bin/classification')]
    with (work / 'build.log').open('w') as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = work / 'bin/RNG_test'
    if originals != {str(p.relative_to(source)): sha256(p.read_bytes())
                     for p in sorted(source.rglob('*')) if p.is_file()}:
        raise RuntimeError('vendored inputs changed during preparation')
    changed = {name for name, digest in originals.items()
               if sha256((frozen / name).read_bytes()) != digest}
    if changed != set(changes):
        raise RuntimeError(f'unexpected private-source changes: {changed}')
    return binary, {
        'reference_version': '0.96',
        'archive_url': 'https://downloads.sourceforge.net/project/pracrand/PractRand_0.96.zip',
        'archive_sha256': 'e4caf7fda98b2c597bbda3b576753cf5a0f6047aab837c82be370ab798a672e1',
        'source_files_sha256': originals,
        'diagnostic_changes': {name: {'original_sha256': sha256(before),
                                     'diagnostic_sha256': sha256(after)}
                               for name, (before, after) in changes.items()},
        'diagnostic_patch': patch,
        'executable_sha256': sha256(binary.read_bytes()),
        'capture_tool_sha256': sha256(Path(__file__).read_bytes()),
        'reference_builder_sha256': sha256((ROOT / 'tools/build_reference.py').read_bytes()),
        'compiler': subprocess.check_output(['clang++', '--version'], text=True),
        'build_command': command,
        'build_flags': ['-O3', '-std=c++11', '-pthread'] +
                       (['-arch', 'x86_64'] if platform.system() == 'Darwin' else []),
        'host': {'system': platform.system(), 'release': platform.release(),
                 'machine': platform.machine()},
    }


def arguments(generator, last):
    return [generator, '-seed', '0', '-te', '1', '-tf', '2', '-tlmin', '1K',
            '-tlmaxonly', '-tlmax', str(last), '-a', '-skip_selftest']


def number(text):
    value = float(text)
    if math.isfinite(value):
        return value
    return 'nan' if math.isnan(value) else ('+inf' if value > 0 else '-inf')


class Checkpoint:
    def __init__(self):
        self.report = []
        self.rows = None
        self.length = None
        self.count = None

    def feed(self, line):
        if not line.startswith(MARKER):
            if line.startswith('rng='):
                if self.rows is not None:
                    raise ValueError('new checkpoint before previous checkpoint completed')
                self.report = []
            self.report.append(line)
            return None
        fields = line.rstrip('\n').split('\t')
        kind = fields[1]
        if kind == 'B' and len(fields) == 4 and self.rows is None:
            self.length, self.count = map(int, fields[2:])
            self.rows = []
            return None
        if kind == 'R' and len(fields) == 9 and self.rows is not None:
            self.rows.append(dict(name=fields[2], type=int(fields[3]),
                                  **dict(zip(('raw', 'processed', 'pvalue', 'suspicion', 'weight'),
                                             map(number, fields[4:])))))
            return None
        if kind != 'E' or len(fields) != 3 or self.rows is None:
            raise ValueError(f'invalid capture record: {line!r}')
        headers = [LENGTH.match(s.rstrip('\n')) for s in self.report]
        headers = [h for h in headers if h]
        if len(headers) != 1:
            raise ValueError('checkpoint requires exactly one length header')
        exponent, seconds = int(headers[0][1]), float(headers[0][2])
        names = [r['name'] for r in self.rows]
        displayed = [m[1] for s in self.report if (m := RESULT.match(s))]
        if (self.length != int(fields[2]) or self.length != 1 << exponent or
                len(self.rows) != self.count or not self.rows or
                len(set(names)) != len(names) or names != displayed):
            raise ValueError('incomplete or inconsistent checkpoint')
        if not math.isfinite(seconds) or seconds < 0:
            raise ValueError('invalid elapsed time')
        for row in self.rows:
            p, w = row['pvalue'], row['weight']
            if not isinstance(p, float) or not 0 <= p <= 1 or not isinstance(w, float) or w <= 0:
                raise ValueError('invalid completed result probability or weight')
        record = {'bytes': self.length, 'exponent': exponent, 'elapsed_seconds': seconds,
                  'results': self.rows, 'report': ''.join(self.report)}
        self.rows = None
        self.report = []
        return record


def capture(binary, generator, last, destination, work):
    destination.mkdir(parents=True, exist_ok=True)
    previous = None
    if (destination / 'run.json').exists():
        previous = json.loads((destination / 'run.json').read_text())
        if previous['arguments'] != arguments(generator, last):
            raise ValueError('cannot resume a different reference configuration')
        if previous['status'] in ('complete', 'upstream_failed_or_incomplete'):
            return previous
        if previous['status'] != 'capture_failed':
            raise ValueError('a reference capture is already running in this directory')
        # Preserve the interrupted attempt. Checkpoints themselves are immutable.
        attempt = 'attempt-' + sha256(previous['started_at'].encode())[:16] + '.json'
        if not (destination / attempt).exists():
            publish(destination / attempt, previous)
    expected = list(range(FIRST_EXPONENT, last + 1))
    state = {'generator': generator, 'seed_low': 0, 'seed_high': 0,
             'initialization': 'original seed(), including original warmup; not seed_fast()',
             'arguments': arguments(generator, last), 'started_at': now(),
             'capture_tool_sha256': sha256(Path(__file__).read_bytes()),
             'status': 'running', 'target_bytes': 1 << last, 'completed_exponents': []}
    parser = Checkpoint()
    publish(destination / 'run.json', state)
    try:
        with (work / f'{generator}.stdout').open('w') as raw, \
                (work / f'{generator}.stderr').open('w') as error:
            process = subprocess.Popen([str(binary), *state['arguments']],
                                       env={**os.environ, 'PRACTRAND_CAPTURE_VALUES': '1'},
                                       stdout=subprocess.PIPE, stderr=error, text=True, bufsize=1)
            try:
                for line in process.stdout:
                    raw.write(line)
                    if (record := parser.feed(line)) is None:
                        continue
                    index = len(state['completed_exponents'])
                    if index >= len(expected) or record['exponent'] != expected[index]:
                        raise ValueError('unexpected checkpoint sequence')
                    checkpoint = destination / f'2^{record["exponent"]}.json'
                    if checkpoint.exists():
                        saved = json.loads(checkpoint.read_text())
                        clean = lambda text: re.sub(r'time=\s*[\d.]+ seconds', 'time=<ignored>', text)
                        if (saved['bytes'] != record['bytes'] or saved['results'] != record['results'] or
                                clean(saved['report']) != clean(record['report'])):
                            raise ValueError(f'repeated checkpoint differs from retained fixture: {checkpoint}')
                    else:
                        publish(checkpoint, record)
                    state['completed_exponents'].append(record['exponent'])
                    publish(destination / 'run.json', state)
                    print(f'{generator}: captured 2^{record["exponent"]} bytes '
                          f'({len(record["results"])} rows, {record["elapsed_seconds"]} s)', flush=True)
                state['exit_code'] = process.wait()
            except BaseException:
                process.kill()
                process.wait()
                raise
            finally:
                process.stdout.close()
        state['stderr'] = (work / f'{generator}.stderr').read_text()
        state['trailing_report'] = ''.join(parser.report)
        complete = (state['exit_code'] == 0 and not state['stderr'] and
                    state['completed_exponents'] == expected and parser.rows is None)
        state['status'] = 'complete' if complete else 'upstream_failed_or_incomplete'
    except BaseException as error:
        state['status'] = 'capture_failed'
        state['capture_error'] = repr(error)
        raise
    finally:
        state['finished_at'] = now()
        publish(destination / 'run.json', state)
    return state


def verify(binary, work):
    """Check the observer and deterministic seed before starting long captures."""
    probe_source = work / 'probe-source'
    probe_source.mkdir()
    rewrite_inputs = {name: (ROOT / 'src' / name).read_bytes()
                      for name in ('classification.zig', 'auxiliary.zig')}
    rewrite_driver = (ROOT / 'test/classification_bytes.zig').read_bytes()
    for name, contents in rewrite_inputs.items():
        (probe_source / name).write_bytes(contents)
    (probe_source / 'main.zig').write_bytes(rewrite_driver)
    rewrite = work / 'bin/rewrite-classification'
    subprocess.run([sys.executable, '-B', str(ROOT / 'tools/zig_run.py'),
                    'build-exe', '-O', 'ReleaseFast', '-lc', '--dep', 'classification',
                    '-Mroot=' + str(probe_source / 'main.zig'),
                    '-Mclassification=' + str(probe_source / 'classification.zig'),
                    '-femit-bin=' + str(rewrite)], cwd=ROOT, check=True)
    original_bytes = subprocess.check_output([str(work / 'bin/classification')])
    rewrite_bytes = subprocess.check_output([str(rewrite)])
    if not original_bytes or original_bytes != rewrite_bytes:
        raise ValueError('diagnostic original and rewrite classification bytes/state differ')
    counts = {'classification': {'byte_count': len(original_bytes),
                                  'sha256': sha256(original_bytes),
                                  'fixtures': 5, 'schedules_per_fixture': 2,
                                  'includes_next_arbee_word': True,
                                  'rewrite_sources_sha256': {name: sha256(contents) for name, contents in rewrite_inputs.items()},
                                  'original_probe_sha256': sha256((work / 'classification.cpp').read_bytes()),
                                  'rewrite_probe_sha256': sha256(rewrite_driver)}}
    # One representative stream reaches C8's first report without spending
    # minutes on repeated full-battery result extraction for every generator.
    for generator in ('sfc16',):
        records = []
        reports = []
        for trial in range(2):
            directory = work / f'verify-{generator}-{trial}'
            result = capture(binary, generator, 14, directory, work)
            if result['status'] != 'complete':
                raise ValueError(f'short reference verification failed: {result}')
            checkpoints = [json.loads((directory / f'2^{e}.json').read_text())
                           for e in result['completed_exponents']]
            records.append([record['results'] for record in checkpoints])
            reports.append([record['report'] for record in checkpoints])
        if records[0] != records[1]:
            raise ValueError(f'{generator} full-precision results are not deterministic')
        if not any('[C8]' in row['name'] for row in records[0][-1]):
            raise ValueError('short verification did not reach classification results')
        environment = dict(os.environ)
        environment.pop('PRACTRAND_CAPTURE_VALUES', None)
        plain = subprocess.run([str(binary), *arguments(generator, 14)], env=environment,
                               text=True, capture_output=True, check=True)
        if plain.stderr:
            raise ValueError(f'unexpected plain reference stderr: {plain.stderr}')
        clean = lambda text: re.sub(r'time=\s*[\d.]+ seconds', 'time=<ignored>', text)
        # The banner is before the first checkpoint and is retained in raw stdout.
        plain_checkpoints = plain.stdout[plain.stdout.index('rng='):]
        if clean(plain_checkpoints) != clean(''.join(reports[0])):
            raise ValueError(f'{generator} observer changes displayed reports')
        counts[generator] = {'checkpoints_per_trial': len(records[0]),
                             'final_result_rows': len(records[0][-1]),
                             'deterministic_trials': 2, 'observer_report_match': True}
    return counts


def input_prefixes(work):
    byte_count = 1 << 20
    generator = work / 'bin/RNG_output'
    record = {'version': 1, 'bytes': byte_count, 'seed_low': 0, 'seed_high': 0,
              'initialization': 'original seed(), not seed_fast()',
              'source_sha256': sha256((work / 'source/src/RNGs/sfc.cpp').read_bytes()),
              'generator_sha256': sha256(generator.read_bytes()), 'cases': {}}
    for name in GENERATORS:
        arguments = [name, str(byte_count), '0']
        result = subprocess.run([str(generator), *arguments], capture_output=True, check=True)
        if result.stderr or len(result.stdout) != byte_count:
            raise ValueError(f'original input-prefix capture failed: {name}')
        record['cases'][name] = {'sha256': sha256(result.stdout), 'reference_arguments': arguments}
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--last-exponent', type=int, default=DEFAULT_LAST_EXPONENT)
    parser.add_argument('--resume', action='store_true',
                        help='restart interrupted cases, checking and preserving their completed fixtures')
    options = parser.parse_args()
    if not FIRST_EXPONENT <= options.last_exponent <= 40:
        parser.error('--last-exponent must be between 10 and 40')
    output = options.output.resolve()
    if output.exists() and not options.resume:
        parser.error(f'output already exists; preserve it and use a fresh directory: {output}')
    (ROOT / '.work').mkdir(exist_ok=True)
    if options.resume:
        summary = output / 'summary.json'
        if summary.exists() and json.loads(summary.read_text()).get('status') == 'accepted':
            parser.error('reference is finalized; reproduce into a fresh --output directory instead')
        provenance = json.loads((output / 'provenance.json').read_text())
        if provenance['last_exponent'] != options.last_exponent:
            parser.error('resume must retain the recorded last exponent')
        work = Path(provenance['work_directory'])
        binary = work / 'bin/RNG_test'
        if sha256(binary.read_bytes()) != provenance['executable_sha256']:
            raise ValueError('cannot resume with a changed reference executable')
        # Legacy captures retain their original executable/dependency contract.
        # New captures must resume under the environment already recorded.
        if 'nix_environment' in provenance:
            if provenance['nix_environment'] != retain_environment(output):
                raise ValueError('cannot resume with a changed Nix environment')
    else:
        work = (options.work_dir.resolve() if options.work_dir else
                Path(tempfile.mkdtemp(prefix='reference-sfc-', dir=ROOT / '.work')))
        work.mkdir(parents=True, exist_ok=True)
        retain_environment(work)
        print(f'Building reference in {work}', flush=True)
        binary, provenance = prepare(work)
        provenance['verification'] = verify(binary, work)
        provenance.update(format_version=1, created_at=now(), generators=list(GENERATORS),
                      generator_seed={'low': 0, 'high': 0, 'initialization': 'original seed()'},
                      classification_seed={'low': C8_SEED, 'high': '0x0', 'scope': 'each C8 stream'},
                      classification_bit_consumption='all 64 bits, low byte first; one byte per classification',
                      battery='Expanded', folding='extra', first_exponent=FIRST_EXPONENT,
                      last_exponent=options.last_exponent,
                      weight='normalized by the original reporter in original result order',
                      numbers='binary64 values round-tripped through %.17g; nonfinite values use strings',
                      work_directory=str(work), reproduction_command=['python3', '-B',
                          'tools/capture_reference.py', '--output', str(output),
                          '--last-exponent', str(options.last_exponent)])
        output.mkdir(parents=True, exist_ok=False)
        provenance['nix_environment'] = retain_environment(output)
        publish(output / 'provenance.json', provenance)
    if not (output / 'input-prefixes.json').exists():
        publish(output / 'input-prefixes.json', input_prefixes(work))
    # Original CLI execution is single-threaded by default. Three independent
    # cases use three cores; each retains its own statistical and output state.
    with ThreadPoolExecutor(max_workers=len(GENERATORS)) as executor:
        states = list(executor.map(lambda generator: capture(binary, generator,
            options.last_exponent, output / generator, work), GENERATORS))
    publish(output / 'summary.json', {'finished_at': now(),
                                    'cases': {s['generator']: s['status'] for s in states}})
    return 0 if all(s['status'] == 'complete' for s in states) else 1


if __name__ == '__main__':
    sys.exit(main())
