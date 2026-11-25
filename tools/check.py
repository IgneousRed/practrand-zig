"""Run dependency-free checks on maintained code without modifying sources."""
import ast
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

from job_runtime import active_environment
from acquire_reference import ensure

active_environment()
upstream = ensure()

for path in sorted([*Path('tools').glob('*.py'), *Path('test').glob('*.py'),
                    *Path('scripts').glob('*.py'), *Path('nix').rglob('*.py')]):
    ast.parse(path.read_text(), filename=str(path))
# Imported observations retain the generator's compact output format.
generated = ('calibration_data.zig', 'permutation_data.zig')
zig_sources = ['build.zig', *(str(path) for path in sorted(Path('src').glob('*.zig'))
                             if path.name not in generated),
               *(str(path) for path in sorted(Path('test').glob('*.zig')))]
subprocess.run(['zig', 'fmt', '--check', *zig_sources], check=True)
# Compile-only actions avoid Nix's injected link flags without suppressing any
# diagnostics. Discard objects so checks leave no build output in the sources.
warnings = ['-Wall', '-Wextra', '-Wpedantic', '-Werror', '-c']
for source in ('tools/sfc8.c', 'test/sfc_stream.c'):
    subprocess.run(['clang', *warnings, source, '-o', os.devnull], check=True)
# Match the reference builder's target; upstream uses x86 intrinsics on macOS.
arch = ['-arch', 'x86_64'] if platform.system() == 'Darwin' else []
for source in sorted(Path('test').glob('*.cpp')):
    # Frozen capture drivers include upstream headers that assume these standard
    # declarations are already available; preserve their recorded source hashes.
    subprocess.run(['clang++', '-std=c++11', '-include', 'cmath', '-include', 'cstdlib', *arch, *warnings,
                    '-isystem', str(upstream / 'include'), '-isystem', str(upstream),
                    str(source), '-o', os.devnull], check=True)
# Check generated observations without reformatting or replacing maintained data.
Path('.work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='check-data-', dir='.work') as directory:
    outputs = [Path(directory) / name for name in generated]
    subprocess.run([sys.executable, '-B', 'tools/import_calibration.py',
                    str(upstream / 'src/tests_core.cpp'), '--output', str(outputs[0]),
                    '--permutation-output', str(outputs[1])], check=True)
    for output in outputs:
        if output.read_bytes() != (Path('src') / output.name).read_bytes():
            raise RuntimeError(f'src/{output.name} differs from regenerated upstream data')
print('Zig formatting, Python syntax, maintained C/C++ warning/compile checks, and imported data passed')
