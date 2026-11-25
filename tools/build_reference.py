"""Build an isolated reference driver and optional CLI tools from untouched PractRand."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import platform
import subprocess
import tempfile

from job_runtime import active_environment, retain_environment
from acquire_reference import ensure

DEFAULT_JOBS = 4
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, nargs='?',
                    help='explicit isolated source, otherwise acquire the pinned .vendor/PractRand view')
parser.add_argument('--output', type=Path, default=Path('.work/validation/reference-values'))
parser.add_argument('--driver', type=Path, default=Path(__file__).resolve().parent.parent / 'test/reference_values.cpp',
                    help='isolated C++ driver (default: test/reference_values.cpp)')
parser.add_argument('--tools', action='store_true', help='also build RNG_test and RNG_output beside the diagnostic driver')
parser.add_argument('--arch', default='x86_64' if platform.system() == 'Darwin' else None)
parser.add_argument('--jobs', type=int, default=DEFAULT_JOBS)
args = parser.parse_args()
environment = active_environment()
if args.jobs < 1: parser.error('--jobs must be positive')
environment_directory = args.output.with_name(args.output.name + '-nix')
existing_outputs = [args.output]
if args.tools:
    existing_outputs += [args.output.parent / name for name in ('RNG_test', 'RNG_output')]
if any(path.exists() for path in existing_outputs) and not environment_directory.exists():
    parser.error('preserve historical executables; select a fresh --output directory for a Nix build')
retain_environment(environment_directory)
source = args.source.resolve() if args.source is not None else ensure().resolve()
files = sorted([*source.glob('src/*.cpp'), *source.glob('src/RNGs/*.cpp'), *source.glob('src/RNGs/other/*.cpp')])
if not files: parser.error('source directory has no PractRand sources')
# Upstream headers assume these declarations are available. Supply them without
# editing the frozen capture drivers or their recorded source hashes.
flags = ['-O3', '-std=c++11', '-pthread', '-include', 'cmath', '-include', 'cstdlib']
if args.arch: flags += ['-arch', args.arch]
# Capture all compiler inputs before starting parallel compilation.
inputs = {path.relative_to(source): path.read_bytes()
          for path in files + sorted(p for p in (source / 'include').rglob('*') if p.is_file())}
tool_inputs = {path.relative_to(source): path.read_bytes() for path in (source / 'tools').glob('*.h')}
if args.tools:
    for name in ('RNG_test', 'RNG_output'):
        relative = Path('tools') / (name + '.cpp')
        tool_inputs[relative] = (source / relative).read_bytes()
driver_bytes = args.driver.read_bytes()
fingerprint = hashlib.sha256(subprocess.check_output(['clang++', '--version']) + repr(flags).encode())
fingerprint.update(environment.encode())
for relative, data in inputs.items():
    fingerprint.update(str(relative).encode())
    fingerprint.update(data)
cache = Path('.work/reference-build') / fingerprint.hexdigest()
cache.mkdir(parents=True, exist_ok=True)
library = cache / 'libPractRand.a'
# Tool-only inputs do not affect the cached library's fingerprint.
inputs.update(tool_inputs)
with tempfile.TemporaryDirectory(prefix='build-', dir=cache) as directory:
    staging = Path(directory)
    frozen = staging / 'source'
    for relative, data in inputs.items():
        path = frozen / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    # Drivers can include private upstream sources from the captured source root.
    frozen_flags = [*flags, '-I', str(frozen / 'include'), '-I', str(frozen)]
    if not library.exists():
        def compile_source(path):
            relative = path.relative_to(source)
            obj = staging / 'objects' / relative.with_suffix('.o')
            obj.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['clang++', *frozen_flags, '-c', str(frozen / relative), '-o', str(obj)], check=True)
            return obj
        with ThreadPoolExecutor(max_workers=args.jobs) as executor:
            objects = list(executor.map(compile_source, files))
        archive = staging / library.name
        subprocess.run(['ar', 'rcs', str(archive), *map(str, objects)], check=True)
        archive.replace(library)
    driver = staging / 'driver.cpp'
    driver.write_bytes(driver_bytes)
    programs = [(driver, args.output)]
    if args.tools:
        programs += [(frozen / 'tools' / (name + '.cpp'), args.output.parent / name)
                     for name in ('RNG_test', 'RNG_output')]
    for driver, output in programs:
        output.parent.mkdir(parents=True, exist_ok=True)
        # Stage beside the destination so publication is an atomic same-filesystem rename.
        with tempfile.TemporaryDirectory(prefix='link-', dir=output.parent) as link_directory:
            binary = Path(link_directory) / output.name
            subprocess.run(['clang++', *frozen_flags, str(driver), str(library), '-o', str(binary)], check=True)
            binary.replace(output)
        print(output)
