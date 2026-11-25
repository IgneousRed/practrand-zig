"""Exercise stream fan-out and completion checks with fake processes only."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import compare_reference as parity


class Input:
    def __init__(self):
        self.data = bytearray()
        self.closed = False

    def write(self, data):
        if self.closed:
            raise ValueError('write after close')
        self.data.extend(data)

    def close(self):
        self.closed = True


class Process:
    def __init__(self):
        self.stdin = Input()
        self.stdout = io.BytesIO(b'x' * 1024)
        self.code = 0

    def poll(self):
        return self.code

    def wait(self, timeout=None):
        return self.code


class Parity(unittest.TestCase):
    def capture(self, report, reference_exponent=10, rewrite_exponent=10, cache=None,
                data=None, reference_code=0, reference_bytes=b'reference', interrupt_tail=False):
        consumers = []

        def launch(command, **kwargs):
            process = Process()
            if kwargs['stdout'] != parity.subprocess.PIPE:
                text = report[Path(command[0]).name] if isinstance(report, dict) else report
                kwargs['stdout'].write(text.encode())
                kwargs['stdout'].flush()
                if Path(command[0]).name == 'reference':
                    process.code = reference_code
                consumers.append(process)
            else:
                class Producer(io.BytesIO):
                    def read(self, size=-1):
                        if interrupt_tail and self.tell() != 0:
                            raise RuntimeError('interrupted rewrite tail')
                        return super().read(size)
                process.stdout = Producer(data if data is not None else b'x' * (1 << rewrite_exponent))
            return process

        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            for name, contents in [('reference', reference_bytes), ('rewrite', b'rewrite'), ('generator', b'generator')]:
                (root / name).write_bytes(contents)
            args = SimpleNamespace(reference=root / 'reference', rewrite=root / 'rewrite',
                                   output=root, reference_cache=cache)
            with patch.object(parity.subprocess, 'Popen', side_effect=launch), \
                    patch.object(parity, 'LAST_EXPONENT', rewrite_exponent), \
                    patch.object(parity, 'REFERENCE_LAST_EXPONENT', reference_exponent), \
                    redirect_stdout(io.StringIO()):
                result = parity.run_case('fake', 8, [str(root / 'generator')], args)
        return result, consumers

    def test_identical_input_reaches_both_executables(self):
        result, consumers = self.capture('length= 1 kilobyte (2^10 bytes), time= 0 seconds\n')
        self.assertTrue(result['passed'])
        self.assertEqual(len(consumers), 2)
        self.assertEqual(consumers[0].stdin.data, b'x' * 1024)
        self.assertEqual(consumers[0].stdin.data, consumers[1].stdin.data)

    def test_successful_exit_and_matching_text_do_not_hide_early_stop(self):
        result, _ = self.capture('error reading from file\n')
        self.assertTrue(result['reports_match'])
        self.assertFalse(result['complete'])
        self.assertFalse(result['passed'])

    def test_complete_reports_do_not_hide_rejected_input(self):
        with patch.object(Input, 'write', side_effect=BrokenPipeError):
            result, _ = self.capture('length= 1 kilobyte (2^10 bytes), time= 0 seconds\n')
        self.assertTrue(result['complete'])
        self.assertEqual(result['bytes_sent'], {'reference': 0, 'rewrite': 0})
        self.assertFalse(result['passed'])

    def test_reference_stops_at_own_limit_and_compares_shared_prefix(self):
        shared = 'rng=RNG_stdin8, seed=0\nlength= 1 kilobyte (2^10 bytes), time= 0 seconds\n  Gap-16:A R=+1\n\n'
        reports = {'reference': shared,
                   'rewrite': shared + 'rng=RNG_stdin8, seed=0\nlength= 2 kilobytes (2^11 bytes), time= 0 seconds\n  Gap-16:A R=+2\n'}
        with patch.object(parity, 'CHUNK_BYTES', 512):
            result, consumers = self.capture(reports, rewrite_exponent=11)
        self.assertTrue(result['passed'])
        self.assertEqual(result['bytes_sent'], {'reference': 1024, 'rewrite': 2048})
        self.assertEqual(consumers[0].stdin.data, consumers[1].stdin.data[:1024])
        self.assertTrue(consumers[0].stdin.closed)
        self.assertEqual(result['compared_through_bytes'], 1024)
        for role, exponent in [('reference', '10'), ('rewrite', '11')]:
            command = result['commands'][role]
            self.assertEqual(command[command.index('-tlmax') + 1], exponent)

    def test_shared_prefix_does_not_hide_missing_rewrite_checkpoint(self):
        report = 'length= 1 kilobyte (2^10 bytes), time= 0 seconds\n'
        result, _ = self.capture(report, rewrite_exponent=11)
        self.assertTrue(result['reports_match'])
        self.assertFalse(result['complete'])
        self.assertFalse(result['passed'])

    def test_complete_reports_do_not_hide_failed_input_flush(self):
        with patch.object(Input, 'close', side_effect=BrokenPipeError):
            result, _ = self.capture('length= 1 kilobyte (2^10 bytes), time= 0 seconds\n')
        self.assertTrue(result['complete'])
        self.assertEqual(result['input_errors'], {'reference': True, 'rewrite': True})
        self.assertFalse(result['passed'])

    def test_valid_reference_cache_skips_original_and_rechecks_input(self):
        Path('.work').mkdir(exist_ok=True)
        report = 'length= 1 kilobyte (2^10 bytes), time= 0 seconds\n'
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            cache = Path(directory)
            first, consumers = self.capture(report, cache=cache)
            self.assertTrue(first['passed'])
            self.assertFalse(first['reference_cached'])
            self.assertEqual(len(consumers), 2)
            second, consumers = self.capture(report, cache=cache)
            self.assertTrue(second['passed'])
            self.assertTrue(second['reference_cached'])
            self.assertEqual(len(consumers), 1)
            changed, consumers = self.capture(report, cache=cache, data=b'y' * 1024)
            self.assertTrue(changed['reports_match'])
            self.assertTrue(changed['reference_cached'])
            self.assertFalse(changed['reference_input_matches'])
            self.assertFalse(changed['passed'])

    def test_changed_executable_and_corrupt_capture_are_cache_misses(self):
        Path('.work').mkdir(exist_ok=True)
        report = 'length= 1 kilobyte (2^10 bytes), time= 0 seconds\n'
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            cache = Path(directory)
            self.capture(report, cache=cache)
            path = next(cache.glob('*.json'))
            record = json.loads(path.read_text())
            record['report'] += 'tampered result\n'
            path.write_text(json.dumps(record))
            result, consumers = self.capture(report, cache=cache)
            self.assertTrue(result['passed'])
            self.assertFalse(result['reference_cached'])
            self.assertEqual(len(consumers), 2)
            result, consumers = self.capture(report, cache=cache, reference_bytes=b'new reference')
            self.assertTrue(result['passed'])
            self.assertFalse(result['reference_cached'])
            self.assertEqual(len(consumers), 2)
            self.assertEqual(len(list(cache.glob('*.json'))), 2)

    def test_failed_original_is_not_cached_but_completed_original_survives_tail_failure(self):
        Path('.work').mkdir(exist_ok=True)
        report = 'length= 1 kilobyte (2^10 bytes), time= 0 seconds\n'
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            cache = Path(directory)
            result, _ = self.capture(report, cache=cache, reference_code=1)
            self.assertFalse(result['passed'])
            self.assertEqual(list(cache.glob('*.json')), [])
            with patch.object(parity, 'CHUNK_BYTES', 1024), self.assertRaisesRegex(RuntimeError, 'interrupted rewrite tail'):
                self.capture(report, cache=cache, rewrite_exponent=11, interrupt_tail=True)
            self.assertEqual(len(list(cache.glob('*.json'))), 1)


if __name__ == '__main__':
    unittest.main()
