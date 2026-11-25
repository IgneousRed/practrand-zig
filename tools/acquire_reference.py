"""Root the pinned, pristine PractRand source without importing project scratch."""
from pathlib import Path
import os
import platform
import subprocess

from job_runtime import active_environment

ROOT = Path(__file__).resolve().parents[1]


def ensure(root=ROOT):
    active_environment()
    root = Path(root).resolve()
    machine = platform.machine().lower()
    architecture = {'arm64': 'aarch64', 'aarch64': 'aarch64',
                    'x86_64': 'x86_64'}.get(machine)
    operating_system = {'Darwin': 'darwin', 'Linux': 'linux'}.get(platform.system())
    if not architecture or not operating_system:
        raise RuntimeError('no locked PractRand source output for this host')
    attribute = f'packages.{architecture}-{operating_system}.practrand-source'

    def evaluate(suffix):
        return subprocess.check_output([
            str(root / 'scripts/dev'), '--eval', attribute + suffix, '--raw',
            '--option', 'allow-import-from-derivation', 'false',
        ], text=True).strip()

    expected = evaluate('.outPath')
    view = root / '.vendor/PractRand'
    if view.is_symlink():
        if os.readlink(view) != expected:
            raise RuntimeError('unexpected .vendor/PractRand target; preserve it before replacing it')
    elif view.exists():
        raise RuntimeError('.vendor/PractRand must be an immutable Nix view, not mutable source')
    view.parent.mkdir(exist_ok=True)
    derivation = evaluate('.drvPath')
    subprocess.run([
        'nix', '--extra-experimental-features', 'nix-command flakes', 'build',
        '--no-update-lock-file', '--out-link', str(view), derivation + '^out',
    ], check=True)
    if not view.is_symlink() or os.readlink(view) != expected or not view.is_dir():
        raise RuntimeError('the pinned PractRand source view was not registered')
    return view


if __name__ == '__main__':
    print(ensure())
