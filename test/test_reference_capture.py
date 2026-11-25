"""A baseline must never turn partial or inconsistent output into a checkpoint."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from capture_reference import Checkpoint, capture


def checkpoint(name='Example', raw='1.2345678901234567', length=1024):
    return [
        'rng=sfc16, seed=0x0\n',
        'length= 1 kilobyte (2^10 bytes), time= 0.1 seconds\n',
        f'@reference\tB\t{length}\t1\n',
        f'@reference\tR\t{name}\t4\t{raw}\t0.5\t0.5\t0\t1\n',
        f'  {name}                       R=  +1.2  p = 0.500     normal\n',
        '\n',
        f'@reference\tE\t{length}\n',
    ]


class ReferenceCapture(unittest.TestCase):
    def test_full_precision_and_report_are_preserved_separately(self):
        parser = Checkpoint()
        lines = checkpoint(raw='inf')
        for line in lines[:-1]:
            self.assertIsNone(parser.feed(line))
        record = parser.feed(lines[-1])
        self.assertEqual(record['bytes'], 1024)
        self.assertEqual(record['results'][0]['raw'], '+inf')
        self.assertNotIn('@reference', record['report'])
        self.assertIn('R=  +1.2', record['report'])

    def test_inconsistent_length_and_names_are_rejected(self):
        for lines in (checkpoint(length=2048),
                      [line.replace('R=  +1.2', 'X=  +1.2') for line in checkpoint()]):
            with self.subTest(lines=lines):
                parser = Checkpoint()
                with self.assertRaisesRegex(ValueError, 'inconsistent checkpoint'):
                    for line in lines:
                        parser.feed(line)

    def test_duplicate_names_are_rejected(self):
        lines = checkpoint()
        lines[2] = '@reference\tB\t1024\t2\n'
        lines.insert(4, lines[3])
        lines.insert(6, lines[5])
        parser = Checkpoint()
        with self.assertRaisesRegex(ValueError, 'inconsistent checkpoint'):
            for line in lines:
                parser.feed(line)

    def test_partial_process_cannot_publish_an_incomplete_checkpoint(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory).resolve()
            executable = root / 'reference'
            executable.write_text('#!' + sys.executable + '\n'
                                  f'print({"".join(checkpoint()[:-1])!r}, end="")\n')
            executable.chmod(0o755)
            state = capture(executable, 'sfc16', 10, root / 'results', root)
            self.assertEqual(state['status'], 'upstream_failed_or_incomplete')
            self.assertEqual(state['completed_exponents'], [])
            self.assertFalse((root / 'results/2^10.json').exists())

    def test_failure_preserves_completed_checkpoint_without_claiming_success(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory).resolve()
            executable = root / 'reference'
            executable.write_text('#!' + sys.executable + '\n'
                                  f'print({"".join(checkpoint())!r}, end="")\n'
                                  'print("error: upstream numerical failure")\n'
                                  'raise SystemExit(1)\n')
            executable.chmod(0o755)
            state = capture(executable, 'sfc16', 11, root / 'results', root)
            self.assertEqual(state['status'], 'upstream_failed_or_incomplete')
            self.assertEqual(state['completed_exponents'], [10])
            self.assertIn('upstream numerical failure', state['trailing_report'])
            record = json.loads((root / 'results/2^10.json').read_text())
            self.assertEqual(record['results'][0]['raw'], 1.2345678901234567)

    def test_interrupted_attempt_can_restart_without_replacing_saved_values(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory).resolve()
            executable = root / 'reference'
            executable.write_text('#!' + sys.executable + '\n'
                                  f'print({"".join(checkpoint())!r}, end="")\n'
                                  'print("@reference\\tinvalid")\n')
            executable.chmod(0o755)
            with self.assertRaises(ValueError):
                capture(executable, 'sfc16', 10, root / 'results', root)
            retained = (root / 'results/2^10.json').read_bytes()
            executable.write_text('#!' + sys.executable + '\n'
                                  f'print({"".join(checkpoint())!r}, end="")\n')
            state = capture(executable, 'sfc16', 10, root / 'results', root)
            self.assertEqual(state['status'], 'complete')
            self.assertEqual((root / 'results/2^10.json').read_bytes(), retained)
            self.assertEqual(len(list((root / 'results').glob('attempt-*.json'))), 1)


if __name__ == '__main__':
    unittest.main()
