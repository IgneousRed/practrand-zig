"""Check retained original entropy bytes and the freshly built -ttep workflow."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

EXECUTABLE, PROBE = sys.argv[1:3]
FIXTURE = json.loads(Path('test/entropy-vectors.json').read_text())


def reports(text):
    body = text[text.index('length='):]
    body = re.sub(r'^rng=.*\n', '', body, flags=re.MULTILINE)
    return re.sub(r'time= [^\n]+', 'time= TIME', body)


class EntropyCLI(unittest.TestCase):
    def run_case(self, *options, expression='arbee', success=True):
        result = subprocess.run([EXECUTABLE, expression, '-seed', '0', '-tf', '0',
                                 '-singlethreaded', '-tlmaxonly', '-a',
                                 '-tlmin', '1KB', '-tlmax', '1KB', *options],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        if success:
            self.assertEqual(result.stderr, '')
        return result.stdout, result.stderr

    def test_original_vectors_whole_and_irregular(self):
        self.assertEqual(FIXTURE['format_version'], 1)
        self.assertEqual(FIXTURE['reference_version'], '0.96')
        provenance = FIXTURE['provenance']
        self.assertEqual(hashlib.sha256(Path(provenance['driver_path']).read_bytes()).hexdigest(),
                         provenance['driver_sha256'])
        for case in FIXTURE['cases']:
            seed = int(case['seed'], 16)
            for mode in ('whole', 'split'):
                with self.subTest(seed=case['seed'], mode=mode):
                    result = subprocess.run([PROBE, case['expression'], mode, f'{seed & ((1 << 64) - 1):x}',
                                             f'{seed >> 64:x}', str(case['bytes'])],
                                            capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(len(result.stdout), case['bytes'])
                    self.assertEqual(hashlib.sha256(result.stdout).hexdigest(), case['sha256'])
                    self.assertEqual(result.stderr.decode(), f"{case['width']}\n{case['name']}\n")

    def test_lengths_option_order_and_checkpoints(self):
        first, _ = self.run_case('-ttep', '-tlmin', '7', '-tlshow', '8', '-tlmax', '9')
        last, _ = self.run_case('-tlmin', '7', '-tlshow', '8', '-tlmax', '9', '-ttep')
        self.assertEqual(reports(first), reports(last))
        self.assertEqual(re.findall(r'\(2\^(\d+) entropy strings\)', first), ['7', '8', '9'])
        self.assertIn('EntropyPoolingTester(arbee,57to57)', first)
        self.assertNotIn('seed walk =', first)
        kilo, _ = self.run_case('-ttep', '-tlmin', '0.125K', '-tlmax', '0.125K')
        self.assertIn('1 kilobyte (2^7 entropy strings)', kilo)
        one_k, _ = self.run_case('-ttep', '-tlmin', '1K', '-tlmax', '1K')
        self.assertIn('8 kilobytes (2^10 entropy strings)', one_k)
        wrapper_8k, _ = self.run_case('-tlmin', '8KB', '-tlmax', '8KB',
                                      expression='EntropyPoolingTester(arbee,57,57)')
        self.assertEqual(reports(one_k).replace('(2^10 entropy strings)', '(2^13 bytes)'),
                         reports(wrapper_8k))

    def test_history_eviction_and_direct_wrappers_avoid_ub007(self):
        # 262,144 bytes = 32,768 strings (> 2x history_length = 16,384), exercising
        # both minimum-hash insertions (UB007) and history eviction/conflict checks.
        whole = subprocess.run([PROBE, 'arbee', 'whole', '0', '0', '262144'],
                               capture_output=True, timeout=30)
        self.assertEqual(whole.returncode, 0, whole.stderr.decode())
        self.assertEqual(len(whole.stdout), 262144)
        split = subprocess.run([PROBE, 'arbee', 'split', '0', '0', '262144'],
                               capture_output=True, timeout=30)
        self.assertEqual(split.returncode, 0, split.stderr.decode())
        self.assertEqual(whole.stdout, split.stdout)
        for expression in ('EntropyPoolingTester(arbee,57,57)',
                           'EntropyPoolingTester(sha2_based_pool,57,57)',
                           'As8(EntropyPoolingTester(arbee,8,8))'):
            with self.subTest(expression=expression):
                w = subprocess.run([PROBE, expression, 'whole'], capture_output=True, timeout=30)
                s = subprocess.run([PROBE, expression, 'split'], capture_output=True, timeout=30)
                self.assertEqual(w.returncode, 0, w.stderr.decode())
                self.assertEqual(s.returncode, 0, s.stderr.decode())
                self.assertEqual(len(w.stdout), 4099)
                self.assertEqual(w.stdout, s.stdout)
        sha2_cli, _ = self.run_case('-tlmin', '8KB', '-tlmax', '8KB',
                                    expression='EntropyPoolingTester(sha2_based_pool,57,57)')
        self.assertIn('EntropyPoolingTester(sha2_based_pool,57to57)', sha2_cli)
        self.assertIn('8 kilobytes (2^13 bytes)', sha2_cli)

    def test_one_byte_history_rejection_covers_the_entire_seed_space(self):
        reason = 'duplicate-seed rejection can cover the entire seed space, leaving no acceptable next seed'
        for policy in ([], ['--reference-compatible']):
            for expression in ('EntropyPoolingTester(arbee,1,1)',
                               'As8(EntropyPoolingTester(arbee,1,1))',
                               'EntropyPoolingTester(arbee,1,8)',
                               'EntropyPoolingTester(arbee,1suffix,8)'):
                with self.subTest(expression=expression, policy=policy):
                    text, error = self.run_case(*policy, expression=expression, success=False)
                    self.assertIn(reason, error)
                    self.assertNotIn('length=', text)
            # Reject the configuration before constructing/seeding a child
            # expression that would block while priming its stdin reader.
            with subprocess.Popen([EXECUTABLE, 'EntropyPoolingTester(As8(stdin64),1,1)',
                                   *policy], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail('one-byte entropy rejection read stdin')
                out, err = process.communicate()
            self.assertEqual(process.returncode, 1, out + err)
            self.assertIn(reason.encode(), err)
            self.assertNotIn(b'length=', out)
        control, _ = self.run_case('-tlmax', '4KB', expression='EntropyPoolingTester(arbee,2,2)')
        self.assertIn('4 kilobytes', control)

    def test_target_selection_uses_last_target(self):
        output, _ = self.run_case('-ttep', '-ttnormal')
        self.assertIn('(2^10 bytes)', output)
        self.assertNotIn('EntropyPoolingTester', output)
        seeding, _ = self.run_case('-ttep', '-ttseed16')
        self.assertIn('(2^7 seeds)', seeding)
        self.assertIn('SeedingTester(arbee,16)', seeding)
        entropy, _ = self.run_case('-ttseed16', '-ttep')
        self.assertIn('(2^7 entropy strings)', entropy)

    def test_batteries_policies_folding_and_threading_match_wrapper(self):
        for battery, folding in (('0', '1'), ('1', '2')):
            for policy in ([], ['--reference-compatible']):
                with self.subTest(battery=battery, policy=policy):
                    options = ['-te', battery, '-tf', folding, '--full-precision', *policy]
                    entropy, _ = self.run_case('-ttep', '-multithreaded', *options)
                    wrapper, _ = self.run_case(expression='EntropyPoolingTester(arbee,57,57)',
                                               *options)
                    self.assertEqual(reports(entropy).replace('(2^7 entropy strings)', '(2^10 bytes)'),
                                     reports(wrapper))
                    if folding == '1':
                        self.assertIn('folding = standard (64 bit)', entropy)

    def test_unsupported_targets_and_walks_fail_without_reading(self):
        for expression in ('sfc64', 'stdin64', 'As8(stdin64)', 'file64(missing-file)',
                           'EntropyPoolingTester(arbee,57,57)'):
            with self.subTest(expression=expression):
                # An empty, open pipe makes a premature nested read block.
                with subprocess.Popen([EXECUTABLE, expression, '-ttep'], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                        self.fail('invalid entropy target read stdin')
                    out, err = process.communicate()
                self.assertEqual(process.returncode, 1, out + err)
                self.assertIn(b'requires an RNG supporting entropy accumulation', err)
                self.assertNotIn(b'length=', out)
        for walk in ('original', 'gray', 'balanced-gray'):
            text, error = self.run_case('-ttep', '--seed-walk', walk, success=False)
            self.assertIn('--seed-walk requires -ttseed', error)
            self.assertNotIn('length=', text)

    def test_original_sha2_basic_check_rejection_is_reported(self):
        text, error = self.run_case('-ttep', expression='sha2_based_pool', success=False)
        self.assertIn('probably failed basic check 3', error)
        self.assertNotIn('length=', text)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
