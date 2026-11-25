"""Exercise seeding targets against the freshly built CLI, without long batteries."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from acquire_reference import ensure
import unittest

EXECUTABLE = sys.argv[1]
WIDTH_FIXTURE = json.loads(Path('test/seed-width-reports.json').read_text())


class SeedCLI(unittest.TestCase):
    def run_case(self, *options, expression='sfc64', success=True):
        result = subprocess.run([EXECUTABLE, expression, '-seed', '0', '-tf', '0',
                                 '-singlethreaded', '-tlmaxonly', *options],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if success:
            self.assertEqual(result.stderr, '')
        return re.sub(r'time= [^\n]+', 'time= TIME', result.stdout), result.stderr

    def test_default_and_explicit_original_and_option_order(self):
        first, _ = self.run_case('-ttseed16', '-tlmin', '7', '-tlmax', '7')
        explicit, _ = self.run_case('--seed-walk', 'original', '-tlmin', '7',
                                    '-tlmax', '7', '-ttseed16')
        self.assertEqual(first, explicit)
        self.assertIn('SeedingTester(sfc64,16)', first)
        self.assertIn('seed walk = original, bits = 16', first)
        self.assertIn('(2^7 seeds)', first)

    def test_all_walks_and_both_result_policies(self):
        for mode in ('original', 'gray', 'balanced-gray'):
            for policy in ([], ['--reference-compatible']):
                with self.subTest(mode=mode, policy=policy):
                    text, _ = self.run_case('-ttseed64', '--seed-walk', mode,
                                            '-tlmin', '1KB', '-tlmax', '1KB', *policy)
                    self.assertIn(f'seed walk = {mode}, bits = 64', text)
                    self.assertIn('(2^7 seeds)', text)
                    self.assertIn('folding = none', text)

    def test_omitted_width_uses_original_metadata_fallback(self):
        text, _ = self.run_case('-ttseed', '-tlmin', '1KB', '-tlmax', '1KB')
        self.assertIn('seed size metadata unavailable', text)
        self.assertIn('seed walk = original, bits = 128', text)
        self.assertIn('(2^7 seeds)', text)

    def test_seed_lengths_explicit_byte_lengths_and_checkpoints(self):
        text, _ = self.run_case('-tlmin', '1K', '-tlmax', '1K', '-ttseed16')
        self.assertIn('8 kilobytes (2^10 seeds)', text)
        text, _ = self.run_case('-tlmin', '7', '-tlshow', '8', '-tlmax', '9', '-ttseed16')
        self.assertEqual(re.findall(r'\(2\^(\d+) seeds\)', text), ['7', '8', '9'])
        text, _ = self.run_case('-ttseed16', '-ttnormal', '-tlmin', '10', '-tlmax', '10')
        self.assertIn('(2^10 bytes)', text)
        self.assertNotIn('seed walk =', text)

    def test_deterministic_modes_stop_at_cycle_end(self):
        for mode in ('gray', 'balanced-gray'):
            text, _ = self.run_case('-ttseed16', '--seed-walk', mode,
                                    '-tlmin', '16', '-tlmax', '17')
            self.assertIn('(2^16 seeds)', text)
            self.assertNotIn('(2^17 seeds)', text)

    def test_lower_widths_match_retained_original_cli_reports(self):
        self.assertEqual(WIDTH_FIXTURE['reference_version'], '0.96')
        upstream = ensure()
        for path, digest in WIDTH_FIXTURE['provenance']['source_sha256'].items():
            # Keep the original capture's path/hash metadata unchanged.
            source = upstream / Path(path).relative_to('vendor/PractRand')
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), digest)
        for case in WIDTH_FIXTURE['cases']:
            for policy in ([], ['--reference-compatible']):
                with self.subTest(expression=case['expression'], bits=case['bits'], policy=policy):
                    text, _ = self.run_case(f"-ttseed{case['bits']}", '-seed', case['seed'],
                                            '-a', '-tlmin', '1KB', '-tlmax', '1KB', *policy,
                                            expression=case['expression'])
                    self.assertIn(case['checkpoint'], text)
                    self.assertIn(f"seed walk = original, bits = {case['bits']}", text)
                    rows = [line.rstrip() for line in text.splitlines()
                            if line.startswith('  ') and not line.startswith('  Test Name')]
                    self.assertEqual(len(rows), len(case['rows']))
                    if policy:
                        self.assertEqual(rows, case['rows'])

    def test_original_native_width_parsing(self):
        options = ('-tlmin', '1KB', '-tlmax', '1KB')
        canonical, _ = self.run_case('-ttseed8', *options)
        for suffix in ('+8', ' 8', '008', '8suffix'):
            with self.subTest(suffix=suffix):
                actual, _ = self.run_case(f'-ttseed{suffix}', *options)
                self.assertEqual(actual, canonical)
        automatic, _ = self.run_case('-ttseed', *options)
        for suffix in ('0', '-0', 'xyz'):
            with self.subTest(suffix=suffix):
                actual, _ = self.run_case(f'-ttseed{suffix}', *options)
                self.assertEqual(actual, automatic)
        # Parsing must retain the native int range until the last target wins;
        # do not execute upstream's undefined shifts for widths above 128.
        ordinary, _ = self.run_case('-ttnormal', *options)
        overridden, _ = self.run_case('-ttseed2147483647', '-ttnormal', *options)
        self.assertEqual(overridden, ordinary)

    def test_invalid_targets_and_walks_fail_before_testing(self):
        cases = [('-ttseed-1',),
                 ('-ttseed15', '--seed-walk', 'gray'),
                 ('--seed-walk', 'gray', '-ttseed129'),
                 ('--seed-walk', 'gray'), ('-ttseed', '--seed-walk', 'unknown'),
                 ('-ttseed24', '--seed-walk', 'balanced-gray')]
        for options in cases:
            with self.subTest(options=options):
                text, error = self.run_case(*options, success=False)
                self.assertIn('RNG_test:', error)
                self.assertNotIn('length=', text)
        _, error = self.run_case('-ttseed64', expression='stdin64', success=False)
        self.assertIn('requires a seedable RNG', error)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
