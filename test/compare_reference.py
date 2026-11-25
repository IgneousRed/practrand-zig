"""Run SFC8/SFC64: Expanded, extra folding, reference 256 MiB, rewrite 4 GiB.

Fresh reference runs share a generator with the rewrite. Cached reference reports
are reused only when the rewrite receives the same input prefix. Full reporting
starts at 1 KiB; reports are compared through 256 MiB. Statistical failures do not
stop the run. See docs/testing.md for comparison limits.
"""
import argparse
from contextlib import ExitStack
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from job_runtime import snapshot

from reports import checkpoints, normalize
import reference_cache

LAST_EXPONENT = 32
REFERENCE_LAST_EXPONENT = 28
FIRST_EXPONENT = 10
CHUNK_BYTES = 1 << 20
DIFF_PREVIEW_LINES = 20


def run_case(name, width, generator, args):
    commands = {}
    processes = []
    sent = [0, 0]
    input_errors = [False, False]
    generated = 0
    digest = hashlib.sha256()
    reference_digest = hashlib.sha256()
    roles = ('reference', 'rewrite')
    last_exponents = (REFERENCE_LAST_EXPONENT, LAST_EXPONENT)
    limits = [1 << exponent for exponent in last_exponents]
    byte_count = limits[-1]
    for role, executable, exponent in zip(roles, (args.reference, args.rewrite), last_exponents):
        command = [str(executable.resolve()), f'stdin{width}', '-te', '1',
                   '-tf', '2', '-tlmin', '1K', '-tlmax', str(exponent),
                   '-tlmaxonly', '-a', '-seed', '0']
        if role == 'reference':
            command.append('-skip_selftest')
        commands[role] = command
    cache_directory = getattr(args, 'reference_cache', None)
    identity = (reference_cache.identity(args.reference, commands['reference'][1:], generator,
                                        FIRST_EXPONENT, REFERENCE_LAST_EXPONENT)
                if cache_directory is not None else None)
    cached = (reference_cache.load(cache_directory, identity)
              if identity is not None and not getattr(args, 'refresh_reference', False) else None)
    if cached is not None:
        (args.output / f'{name}.reference.txt').write_text(cached['report'])
        (args.output / f'{name}.reference.stderr').write_text('')
        sent[0] = limits[0]
        print(f'CACHE {name}: original reference {reference_cache.key(identity)}', flush=True)
    with ExitStack() as files:
        try:
            consumers = []
            for i, role in enumerate(roles):
                if i == 0 and cached is not None:
                    continue
                out = files.enter_context((args.output / f'{name}.{role}.txt').open('wb'))
                err = files.enter_context((args.output / f'{name}.{role}.stderr').open('wb'))
                process = subprocess.Popen(commands[role], stdin=subprocess.PIPE, stdout=out, stderr=err)
                processes.append(process)
                consumers.append((i, process))
            err = files.enter_context((args.output / f'{name}.generator.stderr').open('wb'))
            producer = subprocess.Popen(generator, stdout=subprocess.PIPE, stderr=err)
            processes.append(producer)
            active = [cached is None, True]
            while generated < byte_count and any(active):
                data = producer.stdout.read(min(CHUNK_BYTES, byte_count - generated))
                if not data:
                    break
                digest.update(data)
                reference_digest.update(data[:max(0, limits[0] - generated)])
                generated += len(data)
                for i, process in consumers:
                    if not active[i]:
                        continue
                    try:
                        portion = data[:limits[i] - sent[i]]
                        process.stdin.write(portion)
                        sent[i] += len(portion)
                        if sent[i] == limits[i]:
                            active[i] = False
                            process.stdin.close()
                            if i == 0 and identity is not None:
                                # Finish and publish the reference before the rewrite's longer tail.
                                status = process.wait()
                                report = (args.output / f'{name}.reference.txt').read_text()
                                errors = (args.output / f'{name}.reference.stderr').read_text()
                                if (status == 0 and not errors and not input_errors[0]
                                        and checkpoints(report) == list(range(FIRST_EXPONENT, REFERENCE_LAST_EXPONENT + 1))):
                                    reference_cache.publish(cache_directory, identity, report,
                                                            reference_digest.hexdigest())
                    except BrokenPipeError:
                        active[i] = False
                        input_errors[i] = True
            for i, process in consumers:
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    input_errors[i] = True
            producer.stdout.close()
            codes = [process.wait() for process in processes]
            if cached is not None:
                codes.insert(0, cached['exit_code'])
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
    outputs = [(args.output / f'{name}.{role}.txt').read_text() for role in roles]
    errors = [(args.output / f'{name}.{role}.stderr').read_text() for role in roles]
    expected, actual = [normalize(output, REFERENCE_LAST_EXPONENT) for output in outputs]
    difference = '\n'.join(difflib.unified_diff(expected, actual, fromfile='reference', tofile='rewrite'))
    (args.output / f'{name}.diff').write_text(difference)
    observed = list(map(checkpoints, outputs))
    complete = all(points == list(range(FIRST_EXPONENT, exponent + 1))
                   for points, exponent in zip(observed, last_exponents))
    generator_errors = (args.output / f'{name}.generator.stderr').read_text()
    reference_input_matches = cached is None or reference_digest.hexdigest() == cached['input_sha256']
    passed = (codes == [0, 0, 0] and not any(errors) and not generator_errors
              and generated == byte_count and sent == limits and not any(input_errors)
              and complete and expected == actual and reference_input_matches)
    result = {'passed': passed, 'requested_bytes': byte_count,
              'requested_bytes_by_role': dict(zip(roles, limits)),
              'compared_through_bytes': 1 << REFERENCE_LAST_EXPONENT,
              'generator': generator, 'commands': commands, 'exit_codes': codes,
              'generated_bytes': generated, 'input_sha256': digest.hexdigest(),
              'reference_input_sha256': reference_digest.hexdigest(),
              'reference_cached': cached is not None,
              'reference_cache_key': reference_cache.key(identity) if identity is not None else None,
              'reference_input_matches': reference_input_matches,
              'bytes_sent': dict(zip(roles, sent)),
              'input_errors': dict(zip(roles, input_errors)),
              'checkpoint_exponents': dict(zip(roles, observed)),
              'complete': complete, 'reports_match': expected == actual}
    print(f'{"PASS" if passed else "FAIL"} {name}: reference/rewrite checkpoints '
          f'{observed[0][-1:]}/{observed[1][-1:]}, exit codes {codes}', flush=True)
    if difference:
        print('\n'.join(difference.splitlines()[:DIFF_PREVIEW_LINES]), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=Path('.work/vendor-validation/RNG_test'))
    parser.add_argument('--rewrite', type=Path, default=Path('zig-out/bin/RNG_test'))
    parser.add_argument('--rng-output', type=Path, default=Path('.work/vendor-validation/RNG_output'))
    parser.add_argument('--output', type=Path, default=Path('.work/parity'))
    parser.add_argument('--reference-cache', type=Path, default=Path('.work/reference-results'),
                        help='successful original reference captures (default: .work/reference-results)')
    parser.add_argument('--refresh-reference', action='store_true', help='rerun the original even if cached')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sfc8 = (args.output / 'sfc8').resolve()
    subprocess.run(['clang', '-O3', 'tools/sfc8.c', '-o', str(sfc8)], check=True)
    byte_count = 1 << LAST_EXPONENT
    with tempfile.TemporaryDirectory(prefix='runtime-', dir=args.output) as directory:
        paths, manifest = snapshot({'reference': args.reference, 'rewrite': args.rewrite,
                                    'rng-output': args.rng_output, 'sfc8': sfc8}, directory)
        (args.output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        args.reference, args.rewrite = paths['reference'], paths['rewrite']
        cases = [('sfc8', 8, [str(paths['sfc8']), '0', str(byte_count)]),
                 ('sfc64', 64, [str(paths['rng-output']), 'sfc64', str(byte_count), '0'])]
        results = {}
        for name, width, generator in cases:
            print(f'RUN {name}: reference {1 << REFERENCE_LAST_EXPONENT} bytes, rewrite {byte_count} bytes, '
                  'Expanded, extra folding, all rows from 1 KiB', flush=True)
            results[name] = run_case(name, width, generator, args)
            results[name]['runtime'] = manifest
            (args.output / f'{name}.json').write_text(json.dumps(results[name], indent=2) + '\n')
        (args.output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
        return 0 if all(result['passed'] for result in results.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
