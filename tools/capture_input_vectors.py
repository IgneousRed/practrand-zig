"""Explicitly capture original 0.96 input expressions; never run by tests."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
if args.output.exists():
    parser.error('destination already exists')
input_path = Path('test/input-bytes.bin')
data = input_path.read_bytes()
expressions = []
for width in ('', '8', '16', '32', '64'):
    for source in (f'stdin{width}', f'file{width}({input_path})'):
        expressions.extend([source, f'As8({source})', f'As16({source})',
                            f'As32({source})', f'As64({source})',
                            f'BDS({source},4)', f'SShrink({source})',
                            f'add({source},sfc64)'])
expressions += ['SeedingTester(sfc64)', 'SeedingTester(sfc32,16)',
                'As8(SeedingTester(sfc16,32))', 'RecursiveSeed64(sfc64)',
                'RecursiveSeed64(sfc32)', 'EntropyPoolingTester(arbee,8,16)',
                'EntropyPoolingTester(arbee,8,8)',
                'EntropyPoolingTester(sha2_based_pool,57,57)']
cases = []
for expression in expressions:
    size = 0 if expression.startswith('EntropyPoolingTester(') else 4099
    command = [str(args.reference.resolve()), expression, '0', '0', str(size)]
    first = subprocess.run(command, input=data, capture_output=True, check=True, timeout=60)
    second = subprocess.run(command, input=data, capture_output=True, check=True, timeout=60)
    if first.stdout != second.stdout or first.stderr != second.stderr or len(first.stdout) != size:
        raise RuntimeError(f'unstable or incomplete reference: {expression}')
    width, name = first.stderr.decode().splitlines()
    cases.append(dict(expression=expression, bytes=size, width=int(width), name=name,
                      sha256=hashlib.sha256(first.stdout).hexdigest()))
fixture = dict(format_version=1, reference_version='0.96', bytes=4099,
               seed='0', input_path=str(input_path), input_sha256=hashlib.sha256(data).hexdigest(),
               provenance=dict(reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                               driver_source=Path('test/reference_rngs.cpp').read_text(),
                               compiler=subprocess.check_output(['clang++', '--version'], text=True),
                               build='python3 -B tools/build_reference.py --driver test/reference_rngs.cpp --output REFERENCE',
                               archive_sha256='e4caf7fda98b2c597bbda3b576753cf5a0f6047aab837c82be370ab798a672e1',
                               architecture='x86_64', seed_api='seed(low64,high64)',
                               capture_source=Path(__file__).read_text()), cases=cases)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(fixture, indent=2) + '\n')
print(f'{len(cases)} repeated original captures saved to {args.output}')
