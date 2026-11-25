"""Check strict fixture comparison without running a statistical battery."""
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

from compare_fixtures import differences, load_reference, report_rows, run_case
from reference_fixtures import concatenate, json_bytes


def report(rows, exponent=10):
    return f'length= 1 kilobyte (2^{exponent} bytes), time= 0.1 seconds\n' + ''.join(
        f'  {name:34}R={value}  p = 0.500     normal\n' for name, value in rows)


class Fixtures(unittest.TestCase):
    def test_concatenation_preserves_original_hashes_and_requires_accepted_manifest(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            source = root / 'original'
            (source / 'sfc16').mkdir(parents=True)
            name = 'sfc16/2^10.json'
            original = json_bytes({'report': report([('Gap-16:A', '+1')])})
            (source / name).write_bytes(original)
            summary = {'status': 'accepted', 'checkpoint_sha256': {
                name: hashlib.sha256(original).hexdigest()}}
            (source / 'summary.json').write_bytes(json_bytes(summary))
            path = root / 'reference.json'
            concatenate(source, path)
            self.assertEqual(json_bytes(load_reference(path)[name]), original)
            with self.assertRaises(FileExistsError):
                concatenate(source, path)
            reference = json.loads(path.read_bytes())
            for case in ('missing_summary', 'unaccepted', 'missing_hash', 'missing_record', 'changed'):
                with self.subTest(case=case):
                    modified = json.loads(json.dumps(reference))
                    records = modified['records']
                    if case == 'missing_summary':
                        del records['summary.json']
                    elif case == 'unaccepted':
                        records['summary.json']['status'] = 'running'
                    elif case == 'missing_hash':
                        records['summary.json']['checkpoint_sha256'].clear()
                    elif case == 'missing_record':
                        del records[name]
                    else:
                        records[name]['report'] += 'changed\n'
                    path.write_bytes(json_bytes(modified))
                    with self.assertRaises((ValueError, KeyError)):
                        load_reference(path)

    def test_real_pipes_require_input_delivery_all_checkpoints_and_clean_errors(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory).resolve()
            generator = root / 'generator'
            generator.write_text('#!' + sys.executable + '\nimport sys\n'
                                 'sys.stdout.buffer.write(b"x" * int(sys.argv[2]))\n')
            generator.chmod(0o755)
            executable = root / 'tester'
            text = ''.join(report([('Gap-16:A', '+1')], exponent) for exponent in range(10, 22))
            expected = report_rows(text)
            prefix = hashlib.sha256(b'x' * (1 << 20)).hexdigest()
            for case in ('complete', 'missing_last', 'stderr', 'reject_input'):
                with self.subTest(case=case):
                    code = '#!' + sys.executable + '\nimport sys\n'
                    if case != 'reject_input':
                        code += 'sys.stdin.buffer.read()\n'
                    shown = text if case != 'missing_last' else text[:text.rindex('length=')]
                    code += f'print({shown!r}, end="")\n'
                    if case == 'stderr':
                        code += 'print("input error", file=sys.stderr)\n'
                    executable.write_text(code)
                    executable.chmod(0o755)
                    with redirect_stdout(io.StringIO()):
                        result = run_case(executable, generator, 'sfc16', 'improved', 21,
                                          expected, prefix, root)
                    self.assertEqual(result['passed'], case == 'complete')

    def test_reordering_is_allowed_but_values_and_missing_rows_are_checked(self):
        expected = report_rows(report([('Gap-16:A', '+1'), ('[C8]Gap-16:A', '+2')]))
        reordered = report_rows(report([('[C8]Gap-16:A', '+2'), ('Gap-16:A', '+1')]))
        self.assertEqual(differences(expected, reordered), '')
        for rows in ([('Gap-16:A', '+1'), ('[C8]Gap-16:A', '+3')],
                     [('Gap-16:A', '+1')],
                     [('Gap-16:A', '+2'), ('[C8]Gap-16:A', '+2')]):
            with self.subTest(rows=rows):
                self.assertTrue(differences(expected, report_rows(report(rows))))

    def test_duplicate_names_and_checkpoints_are_errors(self):
        with self.assertRaisesRegex(ValueError, 'duplicate test name'):
            report_rows(report([('Gap-16:A', '+1'), ('Gap-16:A', '+1')]))
        with self.assertRaisesRegex(ValueError, 'duplicate checkpoint'):
            report_rows(report([]) + report([]))

    def test_missing_checkpoint_and_upstream_errors_are_not_normalized_away(self):
        expected = report_rows(report([('Gap-16:A', '+1')]))
        self.assertTrue(differences(expected, {}))
        with self.assertRaisesRegex(ValueError, 'error reading'):
            report_rows('error reading from file\n')

    def test_fpf64_correction_is_narrow_and_includes_folded_streams(self):
        expected = report_rows(report([('FPF/64:all', '+1'), ('[Low1/8]FPF/64:all', '+2'),
                                       ('FPF/32:all', '+3'), ('[C8]FPF/4:all', '+4')]))
        corrected = report_rows(report([('FPF/64:(0,14-5)', '+99'),
                                        ('FPF/32:all', '+3'), ('[C8]FPF/4:all', '+4')]))
        self.assertEqual(differences(expected, corrected), '')
        corrected[10]['[C8]FPF/4:all'] += ' changed'
        self.assertTrue(differences(expected, corrected))


if __name__ == '__main__':
    unittest.main()
