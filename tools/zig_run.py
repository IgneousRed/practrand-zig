"""Run a Zig build or test with a private cache, removing it even on failure."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

from job_runtime import active_environment
import vulkan_run

ROOT = Path(__file__).resolve().parents[1]


def main():
    active_environment()
    arguments = sys.argv[1:]
    if vulkan_run.required(arguments) and not os.environ.get('VULKAN_SDK'):
        return vulkan_run.run(['python3', '-B', str(Path(__file__).resolve()), *arguments])
    expected = os.environ.get('PRACTRAND_ZIG_VERSION')
    if not expected:
        sys.exit('Locked Zig version metadata is missing; use ./scripts/dev')
    if subprocess.check_output(['zig', 'version'], text=True).strip() != expected:
        sys.exit('Zig does not match the locked development environment')
    (ROOT / '.work').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zig-run-', dir=ROOT / '.work') as directory:
        command = ['zig', *arguments, '--cache-dir', str(Path(directory) / 'zig-cache')]
        if arguments and arguments[0] == 'build' and not any(
                value in ('-p', '--prefix') or value.startswith('--prefix=') for value in arguments):
            command.extend(['--prefix', str(ROOT / '.work/install')])
        return subprocess.run(command, cwd=ROOT).returncode


if __name__ == '__main__':
    sys.exit(main())
