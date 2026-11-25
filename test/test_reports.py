"""These tests parse saved text; they never execute a statistical battery."""
import unittest

from reports import checkpoints, normalize


class Reports(unittest.TestCase):
    def test_banner_time_and_known_upstream_difference(self):
        text = ('RNG_test using PractRand 0.96\n'
                'length= 1 kilobyte (2^10 bytes), time= 0.1 seconds\n'
                '  [Low1/8]FPF/64:all R=+1.0\n'
                '  Gap-16:A R=+2.0  \n')
        self.assertEqual(normalize(text), [
            'length= 1 kilobyte (2^10 bytes)', '  Gap-16:A R=+2.0'])

    def test_random_classification_keeps_names(self):
        text = '  [C8]DC6 R=+1\n  [Low1/8][C8]Gap-16:A R=-2\n'
        self.assertEqual(normalize(text), ['  [C8]DC6', '  [Low1/8][C8]Gap-16:A'])
        self.assertNotEqual(normalize(text), normalize(text.replace('DC6', 'DC7')))

    def test_other_result_differences_remain_visible(self):
        self.assertNotEqual(normalize('  DC7 R=+1'), normalize('  DC7 R=+2'))

    def test_extreme_rows_sort_and_random_classification_keeps_only_names(self):
        rows = ['  Z R>+99999  p = 0', '  A R<-99999  p = 1',
                '  [C8]DC6 R>+99999  p = 0']
        self.assertEqual(normalize('\n'.join(rows)), normalize('\n'.join(reversed(rows))))
        self.assertEqual(normalize(rows[-1]), ['  [C8]DC6'])
        self.assertEqual(normalize(rows[-1]), normalize('  [C8]DC6 R=-2  p = 0.5'))
        self.assertNotEqual(normalize(rows[0]), normalize(rows[0].replace('p = 0', 'p = 1')))

    def test_row_order_is_normalized_within_each_checkpoint(self):
        header = 'length= 1 kilobyte (2^10 bytes)\n'
        rows = ['  [Low1/8]DC7 R=+3', '  [C8]DC6 R=+2', '  Gap-16:A R=+1']
        later = '\nlength= 2 kilobytes (2^11 bytes)\n  DC7 R=+4\n'
        expected = normalize(header + '\n'.join(rows) + later)
        self.assertEqual(expected, normalize(header + '\n'.join(reversed(rows)) + later))
        self.assertEqual(expected[1:4], ['  Gap-16:A R=+1', '  [C8]DC6', '  [Low1/8]DC7 R=+3'])
        self.assertNotEqual(expected, normalize(header + '\n'.join(rows[1:]) + later))
        self.assertNotEqual(expected, normalize(header + '\n'.join(rows + rows[:1]) + later))

    def test_checkpoint_exponents_preserve_missing_or_repeated_reports(self):
        text = ('length= 1 kilobyte (2^10 bytes), time= 0.1 seconds\n'
                'length= 4 gigabytes (2^32 bytes), time= 99 seconds\n')
        self.assertEqual(checkpoints(text), [10, 32])
        self.assertEqual(checkpoints(text + text), [10, 32, 10, 32])

    def test_comparison_prefix_retains_limit_rows_and_omits_later_reports(self):
        prefix = 'rng=RNG_stdin8, seed=0\nlength= 256 megabytes (2^28 bytes), time= 1 seconds\n  DC7 R=+1\n\n'
        later = 'rng=RNG_stdin8, seed=0\nlength= 512 megabytes (2^29 bytes), time= 2 seconds\nerror: later failure\n'
        self.assertEqual(normalize(prefix + later, 28), normalize(prefix))
        self.assertNotEqual(normalize(prefix + later), normalize(prefix))


if __name__ == '__main__':
    unittest.main()
