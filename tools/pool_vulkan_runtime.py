"""Share frozen macOS Vulkan libraries without changing their recorded bytes."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

LIBRARIES = ('libMoltenVK.dylib', 'libvulkan.1.dylib', 'libvulkan_kosmickrisp.dylib')
DEFAULT_POOL = Path.home() / '.local/share/dev-pool/vulkan'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def pool_runtime(runtime, sdk_version, pool=DEFAULT_POOL, restore_from=None):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', sdk_version):
        raise ValueError('SDK version must be a single safe directory name')
    runtime, pool = Path(runtime).absolute(), Path(pool).expanduser().absolute()
    if runtime.resolve().is_relative_to(pool.resolve()):
        raise ValueError('A published pool bundle cannot be used as a runtime')
    source = runtime if restore_from is None else Path(restore_from).expanduser().absolute()
    if restore_from is None:
        hashes = {name: digest(source / name) for name in LIBRARIES}
        manifest = {'sdk_version': sdk_version, 'sha256': hashes}
    else:
        manifest = json.loads((runtime / 'vulkan-pool.json').read_text())
        hashes = manifest.get('sha256') if isinstance(manifest, dict) else None
        if (not isinstance(hashes, dict) or set(manifest) != {'sdk_version', 'sha256'}
                or manifest.get('sdk_version') != sdk_version or set(hashes) != set(LIBRARIES)
                or any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value)
                       for value in hashes.values())):
            raise ValueError('Recovery manifest does not describe the requested SDK libraries')
        for name in LIBRARIES:
            if digest(source / name) != hashes[name]:
                raise ValueError(f'Recovery library differs: {source / name}')
    encoded = json.dumps(manifest, sort_keys=True, indent=2) + '\n'
    bundle = hashlib.sha256(encoded.encode()).hexdigest()
    version = pool / sdk_version
    version.mkdir(parents=True, exist_ok=True)
    target = version / bundle
    # Serialize publication and alias replacement; published bundles are never updated.
    with (pool / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not target.exists():
            with tempfile.TemporaryDirectory(prefix='.stage-', dir=version) as directory:
                stage = Path(directory) / 'bundle'
                stage.mkdir()
                for name in LIBRARIES:
                    shutil.copy2(source / name, stage / name)
                    if digest(stage / name) != hashes[name]:
                        raise ValueError(f'Library changed during copy: {name}')
                    (stage / name).chmod(0o555)
                (stage / 'manifest.json').write_text(encoded)
                (stage / 'manifest.json').chmod(0o444)
                stage.rename(target)
        if (target / 'manifest.json').read_text() != encoded:
            raise ValueError(f'Pool manifest differs: {target}')
        for name in LIBRARIES:
            if digest(target / name) != hashes[name]:
                raise ValueError(f'Pool library differs: {target / name}')
            if digest(source / name) != hashes[name]:
                raise ValueError(f'Runtime source changed before linking: {source / name}')
        # Existing ICD JSON and provenance keep their paths and exact content.
        with tempfile.TemporaryDirectory(prefix='.pool-links-', dir=runtime) as directory:
            recovery = Path(directory) / 'vulkan-pool.json'
            recovery.write_text(encoded)
            recovery.replace(runtime / recovery.name)
            for name in LIBRARIES:
                link = Path(directory) / name
                link.symlink_to(target / name)
                link.replace(runtime / name)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-version', required=True)
    parser.add_argument('--pool', type=Path, default=DEFAULT_POOL)
    parser.add_argument('--restore-from', type=Path,
                        help='restore a missing bundle from libraries matching vulkan-pool.json')
    parser.add_argument('runtime', type=Path, nargs='+')
    args = parser.parse_args()
    for runtime in args.runtime:
        print(f'{runtime} -> {pool_runtime(runtime, args.sdk_version, args.pool, args.restore_from)}')


if __name__ == '__main__':
    main()
