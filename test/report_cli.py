"""Compare finished report layouts with durable original-formatter captures."""
from pathlib import Path
import re
import subprocess
import sys
import unittest

EXECUTABLE, PROBE = sys.argv[1:3]
FIXTURES = Path(__file__).resolve().parent / 'reference-results' / 'report-tables'


class ReportCLI(unittest.TestCase):
    def run_case(self, *options, success=True):
        result = subprocess.run([EXECUTABLE, 'sfc64', '-seed', '0', '-tf', '0',
                                 '-singlethreaded', '-tlmin', '1KB', '-tlmax', '1KB',
                                 '-tlmaxonly', *options], capture_output=True,
                                text=True, timeout=60)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if success:
            self.assertEqual(result.stderr, '')
        return re.sub(r'time= [^\n]+', 'time= TIME', result.stdout), result.stderr

    def test_original_formatter_fixtures(self):
        for table in ('narrow', 'wide', 'scoring'):
            with self.subTest(table=table):
                result = subprocess.run([PROBE, table], capture_output=True,
                                        text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                rows = ''.join(line + '\n' for line in result.stdout.splitlines()
                               if line.startswith(('  Test Name', '  case')))
                expected = (FIXTURES / f'{table}.txt').read_text()
                self.assertEqual(len(rows.splitlines()), len(expected.splitlines()))
                for number, (actual, original) in enumerate(zip(rows.splitlines(keepends=True),
                                                               expected.splitlines(keepends=True))):
                    with self.subTest(row=number):
                        self.assertEqual(actual, original)

    def test_default_explicit_narrow_and_last_table_wins(self):
        default, _ = self.run_case('-a')
        narrow, _ = self.run_case('-a', '-table_narrow')
        reset, _ = self.run_case('-table_wide', '-a', '-table_scoring', '-table_narrow')
        self.assertEqual(default, narrow)
        self.assertEqual(default, reset)

    def test_layout_survives_filter_option_order_and_both_policies(self):
        for table in ('narrow', 'wide', 'scoring'):
            for policy in ([], ['--reference-compatible']):
                for filtering in (['-a'], ['-p', '1'], ['-e', '1000']):
                    with self.subTest(table=table, policy=policy, filtering=filtering):
                        before, _ = self.run_case(f'-table_{table}', *filtering, *policy)
                        after, _ = self.run_case(*filtering, *policy, f'-table_{table}')
                        self.assertEqual(before, after)
                        self.assertIn({'narrow': 'Processed     Evaluation',
                                       'wide': 'Weight%  Score',
                                       'scoring': 'Sus  WMod Scor'}[table], before)

    def test_full_precision_is_available_in_all_layouts(self):
        for table in ('narrow', 'wide', 'scoring'):
            ordinary, _ = self.run_case('-a', f'-table_{table}')
            precise, _ = self.run_case('--full-precision', f'-table_{table}', '-a')
            stripped = re.sub(r' raw=[^\n]+', '', precise)
            self.assertEqual(ordinary, stripped)
            self.assertIn(' suspicion=', precise)

    def test_unfinished_alternative_remains_unsupported(self):
        text, error = self.run_case('-table_alternative', success=False)
        self.assertIn('unsupported option: -table_alternative', error)
        self.assertNotIn('length=', text)

    def test_metatest_original_checkpoint_fixtures(self):
        fixture = FIXTURES.parent / 'metatests' / 'summaries.txt'
        expected = fixture.read_text()
        for policy in ('reference', 'improved'):
            with self.subTest(policy=policy):
                result = subprocess.run([PROBE, 'metatest', policy], capture_output=True,
                                        text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                summaries = ''.join(line + '\n' for line in result.stdout.splitlines()
                                    if line.startswith(('case=', '  metatest score:')))
                self.assertEqual(summaries, expected)
                # Multiple anomalies can yield an extreme summary without an
                # individual failure. Empty results also have no summary.
                cases = dict(re.findall(r'case=([^\n]+)\n(.*?)(?=case=|\Z)',
                                        result.stdout, re.S))
                self.assertIn('extreme ; probably a failure', cases['combined-eight'])
                self.assertIn('stop=0', cases['combined-eight'])
                self.assertIn('stop=1', cases['individual-failure'])
                self.assertNotIn('metatest score:', cases['empty'])

    def test_metatest_option_order_default_and_checkpoint_reset(self):
        default, _ = self.run_case('-a')
        disabled, _ = self.run_case('-a', '-do_metatest', '-no_metatest')
        self.assertEqual(default, disabled)
        self.assertNotIn('metatest score:', default)
        for table in ('narrow', 'wide', 'scoring'):
            for policy in ([], ['--reference-compatible']):
                with self.subTest(table=table, policy=policy):
                    enabled, _ = self.run_case('-no_metatest', '-do_metatest', '-a',
                                               f'-table_{table}', *policy)
                    self.assertEqual(enabled.count('metatest score:'), 1)
                    without = re.sub(r'  metatest score:[^\n]*\n', '', enabled)
                    ordinary, _ = self.run_case('-a', f'-table_{table}', *policy)
                    self.assertEqual(without, ordinary)
        multiple, _ = self.run_case('-do_metatest', '-a', '-tlmin', '1KB', '-tlmax', '4KB')
        self.assertEqual(multiple.count('metatest score:'), 3)
        # Each cumulative-data checkpoint computes its summary afresh.
        final, _ = self.run_case('-do_metatest', '-a', '-tlmin', '4KB', '-tlmax', '4KB')
        self.assertEqual(re.findall(r'  metatest score:[^\n]+', multiple)[-1],
                         re.findall(r'  metatest score:[^\n]+', final)[0])


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
