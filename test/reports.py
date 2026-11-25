"""Report parsing shared by parity checks and tests that do not run a battery."""
import re

CHECKPOINT = re.compile(r'^length=.*\(2\^(\d+) bytes\)', re.MULTILINE)
RESULT = re.compile(r'^  (.*?)\s+R[=<>]')


def normalize(text, last_exponent=None):
    lines = []
    rows = []
    for line in text.splitlines():
        checkpoint = CHECKPOINT.match(line)
        if checkpoint and last_exponent is not None and int(checkpoint[1]) > last_exponent:
            # The RNG identification line belongs to this later checkpoint too.
            if lines and lines[-1].startswith('rng='):
                lines.pop()
            break
        if 'using PractRand' in line or 'FPF/64:' in line:
            continue
        if '), time= ' in line:
            line = line.split('), time= ')[0] + ')'
        result = RESULT.match(line)
        if result:
            if '[C8]' in line:
                line = line[:result.end(1)]
            rows.append((result[1], line.rstrip()))
            continue
        lines.extend(row for _, row in sorted(rows, key=lambda entry: entry[0]))
        rows.clear()
        lines.append(line.rstrip())
    lines.extend(row for _, row in sorted(rows, key=lambda entry: entry[0]))
    return lines


def checkpoints(text):
    return [int(exponent) for exponent in CHECKPOINT.findall(text)]
