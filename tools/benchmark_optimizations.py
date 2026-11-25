"""Run SFC trials sequentially through the first checkpoint after a minute.

Each executable uses the selected battery (core by default), extra folding, seed
zero, all result rows, and power-of-two checkpoints from 1 KiB. Statistical failures do not stop
the measurement. Captures retain every completed checkpoint for comparisons at
equal input lengths. Run one benchmark at a time to avoid CPU contention.

Without an executable argument, copy --source-dir into a private build directory,
add phase counters there, and compile ReleaseFast. The normal source and installed
executable stay untouched. Example:

    python3 tools/benchmark_optimizations.py --name before --source-dir src
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time
import tempfile

from job_runtime import retain_environment, snapshot


def instrument(text):
    """Instrument a private source copy, keeping normal executable output intact."""
    text, count = re.subn(r'fn now\(\) f64 \{.*?\n\}', '''fn now() f64 {
    var stamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &stamp) != 0) @panic("monotonic clock unavailable");
    return s.f(stamp.sec) + s.f(stamp.nsec) * 0.000000001;
}''', text, count=1, flags=re.S)
    if count != 1:
        raise ValueError('cannot locate the benchmark clock')
    text = text.replace('extern "c" fn printf(',
                        'extern "c" fn fflush(?*anyopaque) c_int;\nextern "c" fn printf(', 1)
    start = '    const start = now();'
    if text.count(start) != 1:
        raise ValueError('cannot locate the start of the run')
    text = text.replace(start, start + '\n    var feed_seconds: f64 = 0;'
                        '\n    var checkpoint_seconds: f64 = 0;\n    var read_seconds: f64 = 0;', 1)
    show = re.compile(r'            if \((try show\([^\n]+\)) and end_on_failure\) return;')
    text, count = show.subn(lambda match: '''            const checkpoint_started = now();
            const failed = CALL;
            checkpoint_seconds += now() - checkpoint_started;
            _ = printf("@timing\\t%llu\\t%.9f\\t%.9f\\t%.9f\\t%.9f\\n", blocks, now() - start, feed_seconds, checkpoint_seconds, read_seconds);
            _ = fflush(null);
            if (failed and end_on_failure) return;'''.replace('CALL', match[1]), text)
    if count != 1:
        raise ValueError('cannot locate checkpoint reporting')
    used = '            var used: usize = 0;'
    if text.count(used) != 1:
        raise ValueError('cannot locate input reading')
    text = text.replace(used, '            const read_started = now();\n' + used, 1)
    feeds = [line for line in text.splitlines()
             if line == '            try streams.update(buffer[0..n], executor);'
             or (line.startswith('            for (streams.items')
                 and line.endswith('try stream.update(buffer[0..n]);'))]
    if len(feeds) != 1:
        raise ValueError('cannot locate feeding')
    feed = feeds[0]
    text = text.replace(feed, '''            read_seconds += now() - read_started;
            const feed_started = now();
FEED
            feed_seconds += now() - feed_started;'''.replace('FEED', feed), 1)
    input_job = 'const InputJob = struct' in text
    if input_job or 'const Feeder = struct' in text:
        # Private counters follow the counting service. Reading and counting
        # overlap, so their durations must not be added to infer elapsed time.
        field = '    bytes: []const u8 = &.{},' if input_job else '    failure: ?anyerror = null,'
        call = ('        try job.streams.update(job.bytes, job.executor);' if input_job else
                '            const result: ?anyerror = if (f.streams.update(bytes, f.executor)) |_| null else |err| err;')
        owner = 'job' if input_job else 'f'
        indent = '        ' if input_job else '            '
        if text.count(field) != 1 or text.count(call) != 1:
            raise ValueError('cannot locate the input counting service')
        text = text.replace(field, field + '\n    benchmark_feed_seconds: f64 = 0,', 1)
        text = text.replace(call, indent + 'const count_started = now();\n' + call
                            + f'\n{indent}{owner}.benchmark_feed_seconds += now() - count_started;', 1)
        wait = 'try feeder.wait(&input_request);' if 'input_request' in text else 'try feeder.wait();'
        branch = '            if (overlap_input) {\n                ' + wait
        join = '\n        if (overlap_input) ' + wait
        if text.count(branch) != 1 or text.count(join) != 1:
            raise ValueError('cannot locate the input pipeline joins')
        text = text.replace(branch, '            if (overlap_input) {\n'
                            '                read_seconds += now() - read_started;\n'
                            '                ' + wait, 1)
        counter = 'input_job' if input_job else 'feeder'
        text = text.replace(join, '\n        if (overlap_input) {\n'
                            f'            {wait}\n'
                            f'            feed_seconds = {counter}.benchmark_feed_seconds;\n        }}', 1)
    return text


def build(source, directory, threads=None):
    source, directory = source.resolve(), directory.resolve()
    if source == directory or source in directory.parents:
        raise ValueError('the private build directory must be outside the source directory')
    directory.mkdir(parents=True, exist_ok=True)
    sources = list(source.glob('*.zig'))
    # A reused directory must not satisfy imports with files removed from source.
    stale = ({path.name for path in directory.glob('*.zig')}
             - {path.name for path in sources} - {'timed_main.zig'})
    if stale:
        raise ValueError('use a fresh private build directory; stale sources: ' + ', '.join(sorted(stale)))
    native_arguments = []
    manifest = source / 'builtin_rng_sources.txt'
    if manifest.exists():
        # Freeze the generator inputs too: main now supports both stdin and RNGs.
        # The C++ runtime is provided by Zig; no external library is downloaded.
        from acquire_reference import ensure
        upstream = ensure(source.parent)
        native_paths = [upstream / name for name in manifest.read_text().splitlines()]
        headers = [path for folder in ('include', 'tools')
                   for path in (upstream / folder).rglob('*') if path.is_file() and path.suffix == '.h']
        captured = {path.relative_to(upstream): path.read_bytes() for path in native_paths + headers}
        adapter = {name: (source / name).read_bytes()
                   for name in ('builtin_rngs.cpp', 'builtin_rngs.h', 'builtin_rng_arithmetic.h')}
        frozen = directory / 'rng-vendor'
        for relative, data in captured.items():
            target = frozen / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        for name, data in adapter.items():
            (directory / name).write_bytes(data)
        native_arguments = ['-lc++', '-isystem', str(frozen / 'include'), '-isystem', str(frozen / 'tools'),
                            '-cflags', '-std=c++11', '--', str(directory / 'builtin_rngs.cpp'),
                            *(str(frozen / path.relative_to(upstream)) for path in native_paths)]
    for path in sources:
        shutil.copy2(path, directory / path.name)
    if threads is not None:
        pool = directory / 'worker_pool.zig'
        text, count = re.subn(r'const worker_limit = \d+;', f'const worker_limit = {threads};', pool.read_text())
        if count != 1:
            raise ValueError('cannot locate the private worker limit')
        pool.write_text(text)
    (directory / 'timed_main.zig').write_text(instrument((directory / 'main.zig').read_text()))
    executable = directory / 'RNG_bench'
    cache = directory / 'zig-cache'
    try:
        subprocess.run(['zig', 'build-exe', str(directory / 'timed_main.zig'),
                        '-O', 'ReleaseFast', '-lc', '--cache-dir', str(cache),
                        '-femit-bin=' + str(executable), *native_arguments], check=True)
    finally:
        shutil.rmtree(cache, ignore_errors=True)
    return executable


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def measure(executable, generator, width, seconds, destination, minimum='1K', maximum='50', battery=0):
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [str(executable.resolve()), f'stdin{width}', '-te', str(battery), '-tf', '2',
               '-tlmin', minimum, '-tlmax', maximum, '-tlmaxonly', '-a', '-seed', '0']
    started = time.perf_counter()
    with destination.with_suffix('.stderr').open('wb') as errors:
        producer = subprocess.Popen(generator, stdout=subprocess.PIPE, stderr=errors)
        try:
            tester = subprocess.Popen(command, stdin=producer.stdout, stdout=subprocess.PIPE,
                                      stderr=errors, text=True, bufsize=1)
        except BaseException:
            producer.stdout.close()
            stop(producer)
            raise
        producer.stdout.close()
        checkpoints, lines, current = [], [], None
        try:
            with destination.with_suffix('.txt').open('w') as report:
                for line in tester.stdout:
                    if line.startswith('rng=') and current is not None:
                        raise RuntimeError('missing phase counters: omit the executable argument '
                                           'to build an instrumented copy')
                    report.write(line)
                    lines.append(line.rstrip())
                    match = re.match(r'length=.*\(2\^(\d+) bytes\), time= ([\d.]+) seconds', line)
                    if match:
                        current = {'bytes': 1 << int(match[1]), 'reported_seconds': float(match[2])}
                    if current is not None and not line.strip():
                        current['rows'] = [row for row in lines if row.startswith('  ')]
                    if line.startswith('@timing\t'):
                        _, blocks, wall, feed, checkpoint, reading = line.split()
                        if current is None or current['bytes'] != int(blocks) * 1024:
                            raise RuntimeError('phase counters do not match the reported checkpoint')
                        timings = tuple(map(float, (wall, feed, checkpoint, reading)))
                        if any(not math.isfinite(value) or value < 0 for value in timings) or timings[0] == 0:
                            raise RuntimeError('phase counters must be finite and nonnegative with positive elapsed time')
                        current.update(seconds=timings[0], feed_seconds=timings[1],
                                       checkpoint_seconds=timings[2], read_seconds=timings[3],
                                       process_seconds=time.perf_counter() - started)
                        checkpoints.append(current)
                        print(json.dumps({'checkpoint': current['bytes'],
                                          'seconds': round(current['seconds'], 3),
                                          'feed_seconds': current['feed_seconds'],
                                          'checkpoint_seconds': current['checkpoint_seconds'],
                                          'trial': destination.name}), flush=True)
                        if current['seconds'] > seconds:
                            break
                        lines, current = [], None
                else:
                    raise RuntimeError(f'{destination.name}: tester ended before the time limit')
        finally:
            stop(tester)
            stop(producer)
            tester.stdout.close()
    if destination.with_suffix('.stderr').stat().st_size:
        raise RuntimeError(f'{destination.name}: unexpected stderr; inspect the capture')
    final = checkpoints[-1]
    result = {'command': command, 'generator': generator, 'limit_seconds': seconds,
              'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
              'generator_sha256': hashlib.sha256(Path(generator[0]).read_bytes()).hexdigest(),
              'platform': platform.platform(), 'machine': platform.machine(),
              'folding': 2, 'seed': 0, 'battery': battery,
              'bytes': final['bytes'], 'seconds': final['seconds'],
              'feed_seconds': final['feed_seconds'],
              'checkpoint_seconds': final['checkpoint_seconds'],
              'read_seconds': final['read_seconds'],
              'mib_per_second': final['bytes'] / final['seconds'] / (1 << 20),
              'checkpoints': checkpoints}
    destination.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path, nargs='?', help='an already instrumented executable')
    parser.add_argument('--source-dir', type=Path, default=Path('src'))
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--name', required=True)
    parser.add_argument('--output', type=Path, default=Path('.work/optimizations/results'))
    parser.add_argument('--sfc8', type=Path, help='an existing compiled tools/sfc8.c')
    parser.add_argument('--rng-output', type=Path,
                        default=Path('.work/vendor-validation/RNG_output'))
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--source', choices=('sfc8', 'sfc16', 'sfc64', 'both'), default='both')
    parser.add_argument('--battery', choices=('core', 'expanded'), default='core')
    parser.add_argument('--threads', type=int, help='worker limit in the private build')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.name):
        parser.error('--name must contain only letters, digits, underscores, and hyphens')
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error('--seconds must be finite and positive')
    if args.threads is not None and (args.threads < 1 or args.executable is not None):
        parser.error('--threads requires a positive count and a private source build')
    retained = args.output / (args.name + '-nix')
    if (args.output / (args.name + '-runtime.json')).exists() and not retained.exists():
        parser.error('preserve historical results; choose a fresh --name for a Nix job')
    environment = retain_environment(retained)
    private_build = args.executable is None
    directory = args.build_dir or args.output / 'build' / args.name
    auxiliary_seed = None
    if args.executable is None:
        args.executable = build(args.source_dir, directory, args.threads)
        if args.battery == 'expanded':
            seed = re.search(r'pub const classification_seed: u64 = (0x[0-9a-fA-F_]+);',
                             (directory / 'expanded.zig').read_text())
            if seed is None:
                raise ValueError('cannot locate the private classification seed')
            auxiliary_seed = int(seed[1].replace('_', ''), 16)
    if args.source in ('both', 'sfc8') and args.sfc8 is None:
        directory.mkdir(parents=True, exist_ok=True)
        args.sfc8 = directory / 'sfc8'
        source = Path(__file__).resolve().with_name('sfc8.c')
        subprocess.run(['clang', '-O3', str(source), '-o', str(args.sfc8)], check=True)
    executables = {'tester': args.executable}
    if args.source in ('both', 'sfc8'): executables['sfc8'] = args.sfc8
    if args.source in ('both', 'sfc64'): executables['sfc64'] = args.rng_output
    if args.source == 'sfc16': executables['sfc16'] = args.rng_output
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='runtime-', dir=args.output) as runtime:
        paths, manifest = snapshot(executables, runtime)
        (args.output / f'{args.name}-runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for name, width in (('sfc8', 8), ('sfc16', 16), ('sfc64', 64)):
            if name not in paths:
                continue
            generator = [str(paths[name]), '0', str((1 << 64) - 1)] if name == 'sfc8' else [str(paths[name]), name, 'inf', '0']
            result = measure(paths['tester'], generator, width, args.seconds, args.output / f'{args.name}-{name}',
                             battery=int(args.battery == 'expanded'))
            result.update(worker_limit=args.threads, auxiliary_seed=auxiliary_seed,
                          clock='monotonic' if private_build else 'provided executable',
                          nix_environment=environment)
            (args.output / f'{args.name}-{name}.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps({'completed': args.name, 'source': name, 'bytes': result['bytes'],
                              'seconds': result['seconds'], 'mib_per_second': result['mib_per_second']}), flush=True)


if __name__ == '__main__':
    main()
