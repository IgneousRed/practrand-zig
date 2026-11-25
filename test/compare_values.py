"""Compare captured numerical TSV rows without running a statistical battery.

The operands are captured TSV files. Tolerances accommodate C++ long-double
accumulation versus the native target's floating-point implementation; names,
checkpoints, order, and weights must agree as well.
"""
import argparse
import math
from pathlib import Path

ABSOLUTE_TOLERANCES = (1e-6, 1e-6, 1e-15)
RELATIVE_TOLERANCE = 1e-10

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--nonfinite', action='store_true', help='also require matching NaNs and signed infinities')
parser.add_argument('--exclude-prefix', action='append', default=[],
                    help='exclude an intentionally changed test family from both captures')
parser.add_argument('reference', type=Path)
parser.add_argument('rewrite', type=Path)
args = parser.parse_args()
def rows(path):
    parsed = [line.split('\t') for line in path.read_text().splitlines()]
    if any(len(row) != 5 for row in parsed):
        parser.error(f'{path}: expected five tab-separated columns per row')
    return [row for row in parsed if not row[1].startswith(tuple(args.exclude_prefix))]

a, b = map(rows, (args.reference, args.rewrite))
if not a or len(a) != len(b):
    parser.error(f'nonempty captures must have equal row counts: {len(a)} versus {len(b)}')
worst = [0.0, 0.0, 0.0]
for x, y in zip(a, b):
    if x[:2] != y[:2]:
        parser.error(f'checkpoint/name mismatch: {x[:2]} versus {y[:2]}')
    for i, tolerance in enumerate(ABSOLUTE_TOLERANCES):
        reference, rewrite = float(x[i + 2]), float(y[i + 2])
        if not math.isfinite(reference) or not math.isfinite(rewrite):
            if not (args.nonfinite and ((math.isnan(reference) and math.isnan(rewrite))
                                        or reference == rewrite)):
                parser.error(f'nonfinite mismatch: {x} versus {y}, column {i + 3}')
            continue
        difference = abs(reference - rewrite)
        worst[i] = max(worst[i], difference)
        if not math.isclose(reference, rewrite, rel_tol=RELATIVE_TOLERANCE, abs_tol=tolerance):
            parser.error(f'numerical mismatch: {x} versus {y}, column {i + 3}, error {difference}')
print(f'{len(a)} full-precision rows matched; max absolute errors raw/suspicion/weight: {worst}')
if args.exclude_prefix:
    print('Explicitly excluded test prefixes:', ', '.join(args.exclude_prefix))
