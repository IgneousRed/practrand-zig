"""Check original input vectors and the freshly built stream-input CLI."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

EXECUTABLE, PROBE = sys.argv[1:3]
FIXTURE = json.loads(Path('test/input-vectors.json').read_text())
MULTI_FIXTURE = json.loads(Path('test/multi-input-vectors.json').read_text())
DATA = Path(FIXTURE['input_path']).read_bytes()


def report_body(text):
    # Input identity and elapsed time differ; every statistical row must match.
    body = re.sub(r'^rng=.*\n', '', text[text.index('length='):], flags=re.MULTILINE)
    return re.sub(r'time= [^\n]+', 'time= TIME', body)


class InputCLI(unittest.TestCase):
    def run_case(self, expression, *options, data=DATA):
        return subprocess.run([EXECUTABLE, expression, '-seed', '0', '-tlmaxonly',
                               '-tlmin', '1KB', '-tlmax', '4KB', '-a',
                               '--full-precision', *options], input=data,
                              capture_output=True, timeout=30)

    def test_retained_original_vectors_whole_and_irregular(self):
        for fixture in (FIXTURE, MULTI_FIXTURE):
            self.assertEqual(hashlib.sha256(DATA).hexdigest(), fixture['input_sha256'])
            for case in fixture['cases']:
                for mode in (('whole', 'split') if case['bytes'] else ('metadata',)):
                    with self.subTest(expression=case['expression'], mode=mode):
                        result = subprocess.run([PROBE, case['expression'], mode], input=DATA,
                                                capture_output=True, timeout=30)
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(len(result.stdout), case['bytes'])
                        self.assertEqual(hashlib.sha256(result.stdout).hexdigest(), case['sha256'])
                        self.assertEqual(result.stderr.decode(), f"{case['width']}\n{case['name']}\n")

    def test_multi_reader_reports_match_retained_original_bytes(self):
        for case in MULTI_FIXTURE['cases']:
            output = bytes.fromhex(case['output_hex'])
            self.assertEqual(len(output), case['bytes'])
            self.assertEqual(hashlib.sha256(output).hexdigest(), case['sha256'])
            for policy in ([], ['--reference-compatible']):
                with self.subTest(expression=case['expression'], policy=policy):
                    actual = self.run_case(case['expression'], '-tf', '0', *policy)
                    expected = self.run_case(f"stdin{case['width']}", '-tf', '0', *policy,
                                             data=output)
                    for result in (actual, expected):
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(result.stderr, b'')
                    self.assertEqual(report_body(actual.stdout.decode()),
                                     report_body(expected.stdout.decode()))

    def test_file_and_nested_stdin_match_direct_stdin_reports(self):
        for width in ('', '8', '16', '32', '64'):
            for options in (['-singlethreaded'], ['-te', '1', '-multithreaded', '--reference-compatible']):
                with self.subTest(width=width, options=options):
                    direct = self.run_case(f'stdin{width}', *options)
                    file = self.run_case(f"file{width}({FIXTURE['input_path']})", *options)
                    nested = self.run_case(f'As{width or "Unknown"}(stdin{width})', *options)
                    for result in (direct, file, nested):
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(result.stderr, b'')
                    self.assertEqual(report_body(direct.stdout.decode()), report_body(file.stdout.decode()))
                    self.assertEqual(report_body(direct.stdout.decode()), report_body(nested.stdout.decode()))

    def test_free_form_labels_for_unseedable_sources(self):
        for expression in (f"file64({FIXTURE['input_path']})", 'As8(stdin32)', 'stdin64'):
            result = self.run_case(expression, '-seed', 'external data label', '-tf', '0')
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stderr, b'')
            self.assertIn(b'seed=external data label', result.stdout)

    def test_eof_never_pads_or_reports_a_partial_checkpoint(self):
        with tempfile.TemporaryDirectory(dir='.work', prefix='input-cli-') as directory:
            path = Path(directory) / 'short.bin'
            path.write_bytes(DATA[:1535])
            for expression, data in ((f'file64({path})', b''), ('As8(stdin64)', DATA[:1535])):
                result = self.run_case(expression, '-te', '1', '-tf', '0', data=data)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, b'error reading from file\n')
                self.assertEqual(re.findall(rb'\(2\^(\d+) bytes\)', result.stdout), [b'10'])

    def test_invalid_requests_do_not_read_streams(self):
        cases = [('As8(stdin64)', ['--bad-option']),
                 ('As8(stdin64)', ['-ttseed64']),
                 ('file64(missing-file)', ['-ttseed64']),
                 ('As8(stdin64)', ['-tlmax', 'bad']),
                 ('file64()', []), ('stdin64(extra)', []),
                 ('file64(one,two)', []),
                 ('add64(stdin64,BDS(stdin64,4))', ['-seed', 'not-hex']),
                 ('add64(stdin64,BDS(stdin64,4))', ['--bad-option']),
                 ('add64(stdin64,missing-rng)', [])]
        for expression, options in cases:
            with self.subTest(expression=expression, options=options):
                # Leave the pipe open and empty: a premature read would block.
                with subprocess.Popen([EXECUTABLE, expression, *options], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                        self.fail('invalid input blocked reading stdin')
                    out, err = process.communicate()
                self.assertEqual(process.returncode, 1, out + err)
                self.assertNotIn(b'length=', out)

    def test_multiple_readers_exhaust_before_testing_when_priming_fails(self):
        result = self.run_case('add64(stdin64,stdin64)', '-tf', '0', data=DATA[:1535])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'error reading from file\n')
        self.assertNotIn(b'length=', result.stdout)

    def test_composed_file_readers_close_on_teardown_and_failed_priming(self):
        case = MULTI_FIXTURE['cases'][-1]
        result = subprocess.run([PROBE, case['expression'], 'lifecycle'],
                                input=DATA, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(hashlib.sha256(result.stdout).hexdigest(), case['sha256'])
        with tempfile.TemporaryDirectory(dir='.work', prefix='input-close-') as directory:
            expression = f"add64(file64({FIXTURE['input_path']}),file64({directory}/missing))"
            result = subprocess.run([PROBE, expression, 'lifecycle-error'],
                                    input=DATA, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'')

    def test_open_and_read_errors_fail(self):
        for expression, message in (
                ('file64(.work/no-such-input-file)', b'cannot open input file'),
                ('file8(.)', b'error reading from file'),
                ('BDS(file64(.work/no-such-input-file),4)', b'cannot open input file'),
                ('BDS(file8(.),4)', b'error reading from file')):
            with self.subTest(expression=expression):
                result = self.run_case(expression, '-tf', '0')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn(b'length=', result.stdout)

    def test_list_includes_all_original_input_factories(self):
        result = subprocess.run([EXECUTABLE, '--list-rngs'], capture_output=True, check=True)
        names = result.stdout.decode().splitlines()
        for name in ['SeedingTester', 'RecursiveSeed64', 'EntropyPoolingTester',
                     *(source + width for source in ('stdin', 'file') for width in ('', '8', '16', '32', '64'))]:
            self.assertIn(name, names)

    def test_legacy_ranrot_warns_and_fixed_names_are_explicit(self):
        for width in (32, 64):
            original = f'ranrot_var{width}'
            fixed = original + '_fixed'
            for policy in ([], ['--reference-compatible']):
                for expression in (original, f'As8({original})', f'add64({original},{original})'):
                    with self.subTest(expression=expression, policy=policy):
                        result = self.run_case(expression, '-tf', '0', *policy)
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(result.stderr, b'')
                        self.assertEqual(result.stdout.count(b'warning:'), 1)
                        self.assertEqual(result.stdout.count(f'use {fixed}'.encode()), 1)
                        self.assertIn(b'repeats the original 45-word buffer', result.stdout)
                        self.assertIn(b'length=', result.stdout)
                for expression in (fixed, f'As8({fixed})'):
                    with self.subTest(expression=expression, policy=policy):
                        result = self.run_case(expression, '-tf', '0', *policy)
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(result.stderr, b'')
                        self.assertNotIn(b'warning:', result.stdout)
                        self.assertIn(b'length=', result.stdout)
        result = subprocess.run([EXECUTABLE, '--list-rngs'], capture_output=True, check=True)
        for name in ('ranrot_var32', 'ranrot_var64', 'ranrot_var32_fixed', 'ranrot_var64_fixed'):
            self.assertIn(name, result.stdout.decode().splitlines())

    def test_ranrot_warning_composes_with_seed_metadata_warning(self):
        result = self.run_case('ranrot_var32', '-ttseed', '-tf', '0')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.count(b'warning:'), 1)
        self.assertIn(b'seed size metadata unavailable', result.stdout)
        self.assertIn(b'use ranrot_var32_fixed', result.stdout)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
