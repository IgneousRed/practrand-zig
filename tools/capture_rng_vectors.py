"""Explicitly capture builtin vectors from an independently built original driver.

Never called by tests. The destination must be new; retained fixtures are not
overwritten. Build test/reference_rngs.cpp with tools/build_reference.py first.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from acquire_reference import ensure

ROOT = Path(__file__).resolve().parents[1]
BYTES = 4099
SEEDS = ('0', 'fedcba98765432100123456789abcdef')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--architecture', required=True, help='target architecture of the supplied reference executable')
    options = parser.parse_args()
    if options.output.exists():
        parser.error('destination exists; capture into a new path')
    binary = options.reference.resolve()
    factories = subprocess.check_output([str(binary), '--factories'], text=True).splitlines()
    # Stream/special-wrapper coverage has its own fixture and capture driver.
    # Keep reproducing the original generator-only corpus with the extended probe.
    inputs = {source + width for source in ('stdin', 'file') for width in ('', '8', '16', '32', '64')}
    inputs.update(('SeedingTester', 'RecursiveSeed64', 'EntropyPoolingTester'))
    factories = [name for name in factories if name not in inputs]
    upstream = ensure(ROOT)
    source = (upstream / 'tools/RNG_from_name.h').read_text()
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'//[^\n]*', '', source)
    parameterized = {name: int(count) for count, name in
                     re.findall(r'^\s*REGISTER_RNG_([12])\(\s*(\w+)\s*\)', source, re.M)}
    fixed = {
        'lcg': 'lcg(16,64)', 'xlcg': 'xlcg(16,64)', 'clcg': 'clcg(16,64)',
        'cxlcg': 'cxlcg(16,64)', 'np2lcg': 'np2lcg(16,65521,75,1)',
        'bigbadlcg': 'bigbadlcg(16,128,16)', 'bblcg': 'bblcg(16,128,16)',
        'chacha_weakenedA': 'chacha_weakenedA(8)', 'chacha_weakenedB': 'chacha_weakenedB(8)',
        'BDS': 'BDS(sfc32,4)', 'SShrink': 'SShrink(sfc32)', 'AddToSeed': 'AddToSeed(sfc32,3,7)',
    }
    for name in ('xor', 'add', 'add8', 'add16', 'add32', 'add64', 'add_inf', 'add_infinitive', 'addInf'):
        fixed[name] = name + '(sfc16,jsf32)'
    for name in factories:
        if name.startswith(('As', 'Discard')):
            fixed[name] = name + '(sfc64)'
        if name.endswith('_rngs') or name.startswith('nonrecommended_rngs_'):
            fixed[name] = name + '(1)'
    expressions = set()
    for name in factories:
        count = parameterized.get(name, 0)
        expression = fixed.get(name, name + ('(4)' if count == 1 else '(4,4)' if count == 2 else ''))
        expressions.add(expression)
    # Include every catalog expression, not just every factory's representative.
    catalogs = re.findall(r'const char \*(?:recommended_rngs|nonrecommended_\w+)\[\] = \{(.*?)\};', source, re.S)
    removed = {'xsm16', 'xsm32', 'xsm64', 'rarns16', 'rarns32', 'rarns64'}
    for catalog in catalogs:
        expressions.update(name for name in re.findall(r'"([^"]+)"', catalog) if name not in removed)
    cases = []
    for expression in sorted(expressions):
        for seed in SEEDS:
            value = int(seed, 16)
            command = [str(binary), expression, f'{value & ((1 << 64) - 1):x}', f'{value >> 64:x}', str(BYTES)]
            first = subprocess.run(command, capture_output=True, check=True, timeout=30)
            second = subprocess.run(command, capture_output=True, check=True, timeout=30)
            if (first.stdout, first.stderr) != (second.stdout, second.stderr) or len(first.stdout) != BYTES:
                raise ValueError(f'original bytes/name are not deterministic: {expression}, seed {seed}')
            width, name = first.stderr.decode().splitlines()
            width = int(width)
            cases.append({'expression': expression, 'seed': seed, 'name': name,
                          'width': width if width in (8, 16, 32, 64) else 0,
                          'sha256': hashlib.sha256(first.stdout).hexdigest()})
        print(expression, flush=True)
    result = {'format_version': 1, 'reference_version': '0.96', 'bytes': BYTES,
              'seed_api': 'vRNG::seed(low64, high64), matching original RNG_test',
              'reference_executable_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'driver_sha256': hashlib.sha256((ROOT / 'test/reference_rngs.cpp').read_bytes()).hexdigest(),
              'driver_source': (ROOT / 'test/reference_rngs.cpp').read_text(),
              'compiler': subprocess.check_output(['clang++', '--version'], text=True),
              'architecture': options.architecture, 'optimization': '-O3, no fast math',
              'factory_names': factories,
              'source_sha256': {str(path.relative_to(upstream)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sorted(upstream.rglob('*')) if path.is_file()},
              'cases': cases}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    with options.output.open('x') as file:
        json.dump(result, file, indent=2)
        file.write('\n')


if __name__ == '__main__':
    main()
