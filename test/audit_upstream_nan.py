"""Manually audit isolated upstream tests; records findings, not a pass/fail battery."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from job_runtime import snapshot
from upstream_data import integer
from acquire_reference import ensure

FAMILIES = (
    'DistC6 DistC7 BCFN BCFN_FF FPF BRank BRank_old mod3_simple mod3n '
    'BirthdaySystematic2 Gap16 GapUniversal1 GapUniversal2 GapUniversal3 '
    'LimitedBigGapPrototype FPMulti Birthday32 Birthday64 BirthdayLambda1 '
    'BirthdaySystematic128 BirthdayAlt Pat5 CoupGap NearSeq NearSeq2 NearSeq3 '
    'Coup16 Coup32 DistFreq4 TripleFreq TripleMirrorFreq TripleMirrorFreqN '
    'TripleMirrorCoup SimpleClassifyWord LPerm16 LPerm16A'
).split()
EXTENDED = set(('GapUniversal1 Pat5 DistFreq4 TripleFreq TripleMirrorFreq '
                'TripleMirrorFreqN TripleMirrorCoup LPerm16 LPerm16A').split())
TIMEOUT_SECONDS = 60


def calibration_inputs(source):
    """Read only names and integer sizes; the upstream library owns the tables."""
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', source.read_text(), flags=re.S)

    pairs = []
    for width in (117, 129):
        start = text.index(f'raw_calibration_data_array{width}[]')
        body = text[start:text.index('\n};', start)]
        for name, blocks in re.findall(r'\{\s*"([^"]+)"\s*,\s*([^,]+)', body):
            pairs.append(f'{name} {integer(blocks)}\n')
    return ''.join(pairs)


def capture(probe, output, name, arguments, stdin=None):
    command = [str(probe), *arguments]
    with (output / f'{name}.tsv').open('w') as out, (output / f'{name}.stderr').open('w') as err:
        try:
            status = subprocess.run(command, input=stdin, text=True, stdout=out,
                                    stderr=err, timeout=TIMEOUT_SECONDS).returncode
        except subprocess.TimeoutExpired:
            status = 'timeout'
    lines = (output / f'{name}.tsv').read_text().splitlines()
    rows = [line for line in lines if line.startswith('row\t')]
    nan_rows = [line for line in rows if line.endswith('\tNAN')]
    return dict(name=name, command=command, exit=status, rows=len(rows),
                nan_rows=len(nan_rows), first_nan=nan_rows[0] if nan_rows else None,
                last_checkpoint=next((line for line in reversed(lines)
                                      if line.startswith('checkpoint\t')), None))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, default=Path('.work/nan-audit/upstream-nan'))
    parser.add_argument('--source', type=Path, help='explicit original tests_core.cpp; default uses the pinned source')
    parser.add_argument('--output', type=Path, default=Path('.work/nan-audit/run'))
    args = parser.parse_args()
    if args.source is None:
        args.source = ensure() / 'src/tests_core.cpp'
    args.output.mkdir(parents=True, exist_ok=True)
    cases = []
    for family in FAMILIES:
        blocks = 32768 if family in EXTENDED else 8192 if family == 'Birthday32' else 1024
        cases.extend((f'{family}.{fixture}', [family, fixture, str(blocks), '0'])
                     for fixture in ('zero', 'ones', 'ramp', 'random'))
        cases.append((f'{family}.empty', [family, 'empty', '0', '1']))
    cases += [('Gap16.rounding', ['Gap16', 'random', '2816', '0']),
              ('Pat5.alternating', ['Pat5', 'alternating', '1024', '0'])]

    # Capture source-derived input and the probe before any batch case starts.
    inputs = calibration_inputs(args.source)
    (args.output / 'calibrations.txt').write_text(inputs)
    with tempfile.TemporaryDirectory(prefix='runtime-', dir=args.output) as directory:
        paths, manifest = snapshot({'probe': args.probe}, directory)
        probe = paths['probe']
        (args.output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        def run(case):
            result = capture(probe, args.output, *case)
            print(f"{result['name']}: exit={result['exit']}, "
                  f"rows={result['rows']}, NaN rows={result['nan_rows']}", flush=True)
            return result

        # Coup32 owns 512 MiB of bitmap; bound concurrency to keep memory predictable.
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(run, cases))
        results.append(capture(probe, args.output, 'math', ['math']))
        results.append(capture(probe, args.output, 'calibration', ['calibration'], inputs))
    (args.output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(args.output / 'summary.json')
    if any(result['exit'] == 'timeout' or result['exit'] == 2 for result in results):
        raise SystemExit('audit incomplete; inspect captured errors')


if __name__ == '__main__':
    main()
