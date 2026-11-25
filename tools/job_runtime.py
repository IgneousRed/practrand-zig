"""Freeze batch inputs and retain the immutable environment used by new jobs."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess


def active_environment():
    environment = os.environ.get('PROJECT_NIX_ENVIRONMENT')
    if not environment or not Path(environment).is_absolute():
        raise SystemExit('Run this tool through ./scripts/dev with the locked Nix environment')
    return environment


def retain_environment(directory):
    """Root the immutable environment for a new retained job, never rebind it."""
    environment = active_environment()
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    root = directory / 'nix-environment'
    if root.is_symlink():
        if root.resolve() != Path(environment).resolve():
            raise ValueError('Retained job uses a different Nix environment; choose a fresh destination')
        return {'store_path': environment, 'gc_root': str(root)}
    elif root.exists():
        raise ValueError('Nix environment root would replace an existing file')
    helper = Path(__file__).resolve().parents[1] / 'scripts/retain-nix-environment'
    subprocess.run([str(helper), str(root)],
                   check=True, stdout=subprocess.DEVNULL)
    return {'store_path': environment, 'gc_root': str(root)}


def snapshot(executables, directory):
    paths, manifest = {}, {}
    for role, executable in executables.items():
        source = Path(executable).resolve()
        target = Path(directory) / role / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        paths[role] = target
        manifest[role] = {'source': str(source),
                          'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    return paths, manifest
