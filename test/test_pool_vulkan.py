"""Verify frozen runtime preservation and content-addressed library reuse."""
from pathlib import Path
import json
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from pool_vulkan_runtime import LIBRARIES, pool_runtime


class PoolVulkan(unittest.TestCase):
    def test_missing_pool_restores_from_verified_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime, sdk, pool = (root / name for name in ('runtime', 'sdk', 'pool'))
            runtime.mkdir()
            sdk.mkdir()
            for name in LIBRARIES:
                (runtime / name).write_bytes(name.encode())
                (sdk / name).write_bytes(name.encode())
            (runtime / 'icd.json').write_text('preserved driver selection')
            target = pool_runtime(runtime, 'sdk', pool)
            recovery = (runtime / 'vulkan-pool.json').read_bytes()
            shutil.rmtree(pool)
            self.assertFalse((runtime / LIBRARIES[0]).exists())
            self.assertEqual(pool_runtime(runtime, 'sdk', pool, sdk), target)
            for name in LIBRARIES:
                self.assertEqual((runtime / name).read_bytes(), name.encode())
            self.assertEqual((runtime / 'vulkan-pool.json').read_bytes(), recovery)
            self.assertEqual((runtime / 'icd.json').read_text(), 'preserved driver selection')

    def test_recovery_rejects_different_bytes_before_relinking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime, sdk, pool = (root / name for name in ('runtime', 'sdk', 'pool'))
            runtime.mkdir()
            sdk.mkdir()
            for name in LIBRARIES:
                (runtime / name).write_bytes(name.encode())
                (sdk / name).write_bytes(name.encode())
            target = pool_runtime(runtime, 'sdk', pool)
            recovery = (runtime / 'vulkan-pool.json').read_bytes()
            links = {name: (runtime / name).readlink() for name in LIBRARIES}
            shutil.rmtree(pool)
            (sdk / LIBRARIES[-1]).write_bytes(b'different SDK build')
            with self.assertRaisesRegex(ValueError, 'Recovery library differs'):
                pool_runtime(runtime, 'sdk', pool, sdk)
            self.assertFalse(target.exists())
            self.assertEqual((runtime / 'vulkan-pool.json').read_bytes(), recovery)
            self.assertEqual({name: (runtime / name).readlink() for name in LIBRARIES}, links)
            with self.assertRaisesRegex(ValueError, 'Recovery manifest'):
                pool_runtime(runtime, 'other-sdk', pool, sdk)
            (runtime / 'vulkan-pool.json').write_text(json.dumps({'sdk_version': 'sdk', 'sha256': {}}))
            with self.assertRaisesRegex(ValueError, 'Recovery manifest'):
                pool_runtime(runtime, 'sdk', pool, sdk)

    def test_reuse_preserves_paths_provenance_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = []
            for label in ('first', 'second'):
                runtime = root / label
                runtime.mkdir()
                for name in LIBRARIES:
                    (runtime / name).write_bytes(name.encode())
                (runtime / 'icd.json').write_text('original absolute path')
                (runtime / 'backend.dylib').write_bytes(b'private backend')
                target = pool_runtime(runtime, '1.4.363.1', root / 'pool')
                targets.append(target)
                self.assertEqual(pool_runtime(runtime, '1.4.363.1', root / 'pool'), target)
                for name in LIBRARIES:
                    self.assertTrue((runtime / name).is_symlink())
                    self.assertEqual((runtime / name).read_bytes(), name.encode())
                self.assertEqual((runtime / 'icd.json').read_text(), 'original absolute path')
                self.assertEqual((runtime / 'backend.dylib').read_bytes(), b'private backend')
            self.assertEqual(*targets)
            # A later SDK install cannot alter an older frozen runtime.
            source = root / 'second' / LIBRARIES[0]
            source.unlink()
            source.write_bytes(b'new SDK library')
            updated = pool_runtime(root / 'second', '1.4.363.1', root / 'pool')
            self.assertNotEqual(updated, targets[0])
            self.assertEqual((root / 'first' / LIBRARIES[0]).read_bytes(), LIBRARIES[0].encode())

    def test_corrupt_pool_is_rejected_before_runtime_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'runtime'
            runtime.mkdir()
            for name in LIBRARIES:
                (runtime / name).write_bytes(name.encode())
            target = pool_runtime(runtime, 'sdk', root / 'pool')
            library = runtime / LIBRARIES[0]
            library.unlink()
            library.write_bytes(LIBRARIES[0].encode())
            pooled = target / LIBRARIES[0]
            pooled.chmod(0o644)
            pooled.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'Pool library differs'):
                pool_runtime(runtime, 'sdk', root / 'pool')
            self.assertFalse(library.is_symlink())
            self.assertEqual(library.read_bytes(), LIBRARIES[0].encode())


if __name__ == '__main__':
    unittest.main()
