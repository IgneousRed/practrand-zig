"""Import immutable PractRand 0.96 calibration observations; no executable C++ is used."""
import argparse
from pathlib import Path
import re
from contextlib import ExitStack
import tempfile

from upstream_data import integer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='original src/tests_core.cpp')
parser.add_argument('--output', type=Path, default=Path('src/calibration_data.zig'))
parser.add_argument('--permutation-output', type=Path, default=Path('src/permutation_data.zig'))
args = parser.parse_args()
s = re.sub(r'/\*.*?\*/|//[^\n]*', '', args.source.read_text(), flags=re.S)
rows = {}
for width in (117, 129):
    start = s.index('raw_calibration_data_array' + str(width) + '[]')
    body = s[start:s.index('\n};', start)]
    pattern = r'\{\s*"([^"]+)"\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*[^,]+\s*,\s*\{([^}]+)\}\s*(?:,([^}]+))?\}'
    for m in re.finditer(pattern, body):
        name, blocks, samples, values, tail = m.groups()
        if not name.startswith(('DC6-9x1', 'DC6-6x2', 'DC6-5x4', 'BCFN-', '_BCFN-', 'FPF', 'Gap-16:', 'BRank', 'mod3_simple')):
            continue
        values = [float(x.strip()) for x in values.split(',') if x.strip()]
        if len(values) != width: raise ValueError((name, len(values)))
        limit = int(tail.split(',')[3].strip()) if width == 129 and tail else (0 if width == 129 else 6)
        if width == 117:
            values = [values[0]] * 6 + values + [values[-1]] * 6
        rows[name, integer(blocks)] = (integer(samples), limit, values)
if len(rows) != 529: raise ValueError('Unexpected PractRand 0.96 calibration row count')
lines = ['// Imported from original PractRand 0.96 (CC0); see LICENSES/PractRand.txt.',
         '// Regenerate with tools/import_calibration.py; values are upstream observations.',
         'pub const Row = struct { name: []const u8, blocks: u64, samples: u64, limit: usize, values: [129]f64 };',
         'pub const rows = [_]Row{']
for (name, blocks), (samples, limit, values) in sorted(rows.items()):
    lines.append('    .{ .name = "' + name + '", .blocks = ' + str(blocks) + ', .samples = ' + str(samples) + ', .limit = ' + str(limit) + ', .values = .{' + ','.join(repr(x) for x in values) + '} },')
lines.append('};\n')
calibration_text = '\n'.join(lines)

other = re.sub(r'/\*.*?\*/|//[^\n]*', '', args.source.with_name('tests_other.cpp').read_text(), flags=re.S)
a = other.index('static const double _lperm16_ratio[]')
a = other.index('{', a) + 1
z = other.index('};', a)
ratios = [float(x.strip()) for x in other[a:z].split(',') if x.strip()]
if len(ratios) != 16384: raise ValueError('Unexpected PractRand 0.96 permutation ratio count')
lines = ['// Imported from original PractRand 0.96 (CC0); see LICENSES/PractRand.txt.',
         '// Empirical LPerm16 ratios; regenerate with tools/import_calibration.py.',
         'pub const ratios = [_]f64{']
for i in range(0, len(ratios), 16):
    lines.append('    ' + ', '.join(repr(x) for x in ratios[i:i+16]) + ',')
lines.append('};\n')
# Both files are parsed, validated and staged before either destination changes.
with ExitStack() as staging:
    pending = []
    for destination, text in ((args.output, calibration_text),
                              (args.permutation_output, '\n'.join(lines))):
        directory = staging.enter_context(tempfile.TemporaryDirectory(prefix='import-', dir=destination.parent))
        path = Path(directory) / destination.name
        path.write_text(text)
        pending.append((path, destination))
    for path, destination in pending:
        path.replace(destination)
print(f'Imported {len(rows)} calibration rows and {len(ratios)} permutation ratios')
