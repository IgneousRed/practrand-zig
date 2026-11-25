"""Publication checks must cover deleted historical paths and renamed content."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Publication(unittest.TestCase):
    def setUp(self):
        (ROOT / '.work').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / '.work')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Synthetic publication check')
        self.git('config', 'user.email', 'publication@example.invalid')
        (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/check-publication', self.root / 'scripts/check-publication')
        (self.root / '.publication-mode').write_text('public\n')
        (self.root / '.publication-files').write_text(
            '.publication-mode\n.publication-files\n.publication-denied-blobs\nREADME.md\nscripts/check-publication\n')
        (self.root / '.publication-denied-blobs').write_text('')
        (self.root / 'README.md').write_text('Reviewed public implementation\n')
        self.commit()

    def git(self, *args, **options):
        return subprocess.check_output(['git', '-C', str(self.root), *args],
                                       stderr=subprocess.STDOUT, **options)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-m', 'Synthetic fixture')

    def check(self, stdin=None):
        return subprocess.run(['sh', 'scripts/check-publication', '--stdin' if stdin else 'main'],
                              cwd=self.root, input=stdin, text=True, capture_output=True)

    def test_reviewed_clean_root_passes_and_cleans_temporary_work(self):
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(list((self.root / '.work').iterdir()), [])

    def test_deleted_private_path_in_an_ancestor_is_rejected(self):
        hidden = self.root / '.private/research.md'
        hidden.parent.mkdir()
        hidden.write_text('Synthetic private research')
        self.commit()
        hidden.unlink()
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reserved source path', result.stderr)

    def test_unclassified_file_requires_review(self):
        (self.root / 'unclassified.txt').write_text('Synthetic unclassified content')
        self.commit()
        self.assertIn('unreviewed outgoing path', self.check().stderr)

    def test_public_root_instructions_are_private_even_if_inventory_lists_them(self):
        (self.root / 'AGENTS.md').write_text('Synthetic private instructions')
        with (self.root / '.publication-files').open('a') as inventory:
            inventory.write('AGENTS.md\n')
        self.commit()
        self.assertIn('private instructions', self.check().stderr)

    def test_deleted_nested_instructions_still_block_public_ancestry(self):
        path = self.root / 'nested/AGENTS.md'
        path.parent.mkdir()
        path.write_text('Synthetic nested private instructions')
        self.commit()
        path.unlink()
        self.commit()
        self.assertIn('private instructions', self.check().stderr)

    def test_private_companion_accepts_versioned_instructions(self):
        (self.root / '.publication-mode').write_text('private\n')
        path = self.root / 'instructions/AGENTS.md'
        path.parent.mkdir()
        path.write_text('Synthetic private instructions')
        with (self.root / '.publication-files').open('a') as inventory:
            inventory.write('instructions/AGENTS.md\n')
        self.commit()
        self.assertEqual(self.check().returncode, 0)

    def test_reclassified_blob_copied_to_an_approved_name_is_rejected(self):
        content = b'Synthetic reclassified record\n'
        blob = self.git('hash-object', '--stdin', input=content).decode().strip()
        (self.root / 'README.md').write_bytes(content)
        (self.root / '.publication-denied-blobs').write_text(blob + '\n')
        self.commit()
        self.assertIn('reclassified or fetched content', self.check().stderr)

    def test_push_accepts_only_the_explicit_main_to_main_ref(self):
        oid = self.git('rev-parse', 'HEAD').decode().strip()
        for local, remote in [('refs/heads/topic', 'refs/heads/main'),
                              ('refs/heads/main', 'refs/backup/main')]:
            result = self.check(f'{local} {oid} {remote} {"0" * 40}\n')
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.check(f'refs/heads/main {oid} refs/heads/main {"0" * 40}\n').returncode, 0)

    def test_symlink_does_not_smuggle_external_material(self):
        (self.root / 'README.md').unlink()
        (self.root / 'README.md').symlink_to('../synthetic-external')
        self.commit()
        self.assertIn('non-regular source entry', self.check().stderr)
