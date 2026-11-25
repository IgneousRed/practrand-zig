"""Check captured job inputs and failure isolation without running a battery."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from job_runtime import retain_environment, snapshot
from upstream_data import integer
import benchmark_optimizations as benchmark
import vulkan_run
from acquire_reference import ensure


class Tools(unittest.TestCase):
    def test_reference_view_is_pinned_rooted_and_reuses_the_declared_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'immutable-source'
            source.mkdir()
            def register(command, **options):
                self.assertIn('--no-update-lock-file', command)
                self.assertEqual(command[-1], '/nix/store/recorded-source.drv^out')
                Path(command[command.index('--out-link') + 1]).symlink_to(source)
            with patch('acquire_reference.active_environment'), \
                    patch('acquire_reference.platform.machine', return_value='arm64'), \
                    patch('acquire_reference.platform.system', return_value='Darwin'), \
                    patch('acquire_reference.subprocess.check_output',
                          side_effect=[str(source), '/nix/store/recorded-source.drv']) as evaluate, \
                    patch('acquire_reference.subprocess.run', side_effect=register):
                view = ensure(root)
                self.assertEqual(view.resolve(), source.resolve())
                self.assertIn('packages.aarch64-darwin.practrand-source.outPath',
                              evaluate.call_args_list[0].args[0])

    def test_reference_acquisition_preserves_foreign_or_mutable_source_views(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                view = root / '.vendor/PractRand'
                view.parent.mkdir()
                foreign = root / 'foreign-source'
                foreign.mkdir()
                (foreign / 'precious.cpp').write_text('retained source')
                if symlink:
                    view.symlink_to(foreign)
                else:
                    view.mkdir()
                    (view / 'precious.cpp').write_text('retained source')
                with patch('acquire_reference.active_environment'), \
                        patch('acquire_reference.platform.machine', return_value='arm64'), \
                        patch('acquire_reference.platform.system', return_value='Darwin'), \
                        patch('acquire_reference.subprocess.check_output', return_value='/nix/store/expected'), \
                        patch('acquire_reference.subprocess.run') as build:
                    with self.assertRaises(RuntimeError):
                        ensure(root)
                    self.assertEqual((view / 'precious.cpp').read_text(), 'retained source')
                    build.assert_not_called()

    def test_vulkan_environment_is_selected_only_for_enabled_build_options(self):
        for arguments, selected in (
                (['build', 'test'], False),
                (['build', '-Dmetal=true'], False),
                (['build', '-Dvulkan=false'], False),
                (['build', '-Dvulkan=true'], True),
                (['build', '-Dvulkan'], True),
                (['build', '-Dvulkan=true', '-Dvulkan=false'], False),
                (['build', '-Dvulkan=false', '-Dvulkan=true'], True),
                (['build', 'run', '--', '-Dvulkan=true'], False),
                (['build', '-Dvulkan=true', '--', '-Dvulkan=false'], True),
                (['build', '-Dvulkan=true', '-Dvulkan-sdk=/recorded/sdk'], False)):
            with self.subTest(arguments=arguments):
                self.assertEqual(vulkan_run.required(arguments), selected)

    def test_existing_vulkan_environment_is_not_reselected(self):
        with patch.dict(os.environ, {'PROJECT_NIX_ENVIRONMENT': '/recorded/environment',
                                     'VULKAN_SDK': '/recorded/sdk'}), \
                patch('vulkan_run.subprocess.run') as run:
            run.return_value.returncode = 7
            self.assertEqual(vulkan_run.run(['recorded-program', 'argument']), 7)
            run.assert_called_once_with(['recorded-program', 'argument'], cwd=vulkan_run.ROOT)

    def test_optional_vulkan_run_uses_canonical_profile_and_command_status(self):
        with patch.dict(os.environ, {'PROJECT_NIX_ENVIRONMENT': '/recorded/cpu',
                                     'VULKAN_SDK': ''}), \
                patch('vulkan_run.subprocess.run') as run:
            run.return_value.returncode = 7
            self.assertEqual(vulkan_run.run(['tester', 'argument']), 7)
            run.assert_called_once_with([
                str(vulkan_run.ROOT / 'scripts/dev'), '--profile', 'vulkan',
                'tester', 'argument',
            ], cwd=vulkan_run.ROOT)

    def test_retained_job_registers_its_environment_without_replacing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            environment, job = root / 'environment', root / 'job'
            environment.mkdir()
            job.mkdir()
            (job / 'capture.txt').write_text('retained result')
            def register(command, **options):
                link = Path(command[1])
                if not link.is_symlink():
                    link.symlink_to(environment)
            with patch.dict(os.environ, {'PROJECT_NIX_ENVIRONMENT': str(environment)}), \
                    patch('job_runtime.subprocess.run', side_effect=register) as run:
                record = retain_environment(job)
                self.assertEqual(retain_environment(job), record)
                self.assertEqual(run.call_count, 1)
            self.assertEqual((job / 'nix-environment').resolve(), environment)
            self.assertEqual((job / 'capture.txt').read_text(), 'retained result')

    def test_retained_job_rejects_environment_rebinding_and_file_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            old, new = root / 'old', root / 'new'
            old.mkdir()
            new.mkdir()
            link = root / 'nix-environment'
            link.symlink_to(old)
            with patch.dict(os.environ, {'PROJECT_NIX_ENVIRONMENT': str(new)}), \
                    patch('job_runtime.subprocess.run') as run:
                with self.assertRaisesRegex(ValueError, 'different Nix environment'):
                    retain_environment(root)
                self.assertEqual(link.resolve(), old)
                link.unlink()
                link.write_text('original file')
                with self.assertRaisesRegex(ValueError, 'replace an existing file'):
                    retain_environment(root)
                self.assertEqual(link.read_text(), 'original file')
                run.assert_not_called()

    def test_private_instrumentation_accepts_maintained_entry_point(self):
        self.assertIn('@timing', benchmark.instrument(Path('src/main.zig').read_text()))

    def test_private_build_rejects_stale_modules_without_changing_previous_sources(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            source, private = root / 'source', root / 'private'
            source.mkdir()
            main = source / 'main.zig'
            main.write_text('const removed = @import("removed.zig");')
            module = source / 'removed.zig'
            module.write_text('pub const value = 1;')
            with patch.object(benchmark, 'instrument', side_effect=lambda text: text), \
                    patch.object(benchmark.subprocess, 'run') as compile:
                benchmark.build(source, private)
                # Healthy reuse accepts the helper's own generated source.
                benchmark.build(source, private)
                self.assertEqual(compile.call_count, 2)
                previous = {path.name: path.read_bytes() for path in private.glob('*.zig')}
                module.unlink()
                main.write_text('const removed = @import("removed.zig"); // changed source')
                with self.assertRaisesRegex(ValueError, 'fresh private build directory.*removed.zig'):
                    benchmark.build(source, private)
                self.assertEqual(compile.call_count, 2)
                self.assertEqual({path.name: path.read_bytes() for path in private.glob('*.zig')}, previous)

    def test_snapshot_survives_replacement_of_original(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            source = root / 'tester'
            source.write_bytes(b'first build')
            source.chmod(0o755)
            paths, manifest = snapshot({'tester': source}, root / 'runtime')
            replacement = root / 'replacement'
            replacement.write_bytes(b'new build')
            replacement.replace(source)
            self.assertEqual(paths['tester'].read_bytes(), b'first build')
            self.assertTrue(paths['tester'].stat().st_mode & 0o111)
            self.assertEqual(manifest['tester']['sha256'], hashlib.sha256(b'first build').hexdigest())

    def test_rejected_permutation_data_preserves_both_generated_files(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            (root / 'tests_core.cpp').write_bytes((ensure() / 'src/tests_core.cpp').read_bytes())
            (root / 'tests_other.cpp').write_text('static const double _lperm16_ratio[] = {0.5};')
            calibration, permutation = root / 'calibration.zig', root / 'permutation.zig'
            calibration.write_text('old calibration')
            permutation.write_text('old permutation')
            result = subprocess.run([sys.executable, '-B', 'tools/import_calibration.py',
                                     str(root / 'tests_core.cpp'), '--output', str(calibration),
                                     '--permutation-output', str(permutation)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calibration.read_text(), 'old calibration')
            self.assertEqual(permutation.read_text(), 'old permutation')

    def test_upstream_integer_syntax_is_shared_and_restricted(self):
        self.assertEqual(integer('(1ULL << 20) + 3 * 4'), (1 << 20) + 12)
        with self.assertRaises(ValueError):
            integer('function_call()')

    def test_optimized_python_cannot_disable_numerical_comparison(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            reference, rewrite = (Path(directory) / name for name in ('reference.tsv', 'rewrite.tsv'))
            reference.write_text('1\tBirthday\t2\t3\t0.5\n')
            for text, options, passed in (
                    ('1\tBirthday\t2\t3\t0.5\n', [], True),
                    ('1\tBirthday\t20\t3\t0.5\n', [], False),
                    ('2\tBirthday\t2\t3\t0.5\n', [], False),
                    ('1\tBirthday\tnan\t3\t0.5\n', ['--nonfinite'], False),
                    ('malformed\n', [], False),
                    ('', [], False)):
                with self.subTest(text=text):
                    rewrite.write_text(text)
                    result = subprocess.run([sys.executable, '-O', '-B', 'test/compare_values.py',
                                             *options, str(reference), str(rewrite)], capture_output=True)
                    self.assertEqual(result.returncode == 0, passed, result.stderr.decode())
                    if not passed:
                        self.assertNotIn(b'full-precision rows matched', result.stdout)

    def test_optimized_python_rejects_invalid_benchmark_timings(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            root = Path(directory)
            tester = root / 'tester'
            code = ("import sys; from pathlib import Path; sys.path.insert(0, 'tools'); "
                    "from benchmark_optimizations import measure; "
                    "measure(Path(sys.argv[1]), [sys.executable, '-c', 'pass'], "
                    "8, 1, Path(sys.argv[2]))")
            valid = ['2.0', '0.5', '0.5', '0.5']
            cases = [(1, valid, True), (2, valid, False)]
            for column in range(4):
                for value in ('nan', 'inf', '-inf', '-1'):
                    timings = valid.copy()
                    timings[column] = value
                    cases.append((1, timings, False))
            cases.append((1, ['0', '0', '0', '0'], False))
            for case, (blocks, timings, passed) in enumerate(cases):
                with self.subTest(blocks=blocks, timings=timings):
                    tester.write_text('#!/usr/bin/env python3\n'
                                      "print('length= 1 kilobyte (2^10 bytes), time= 2 seconds')\n"
                                      f"print('@timing\\t{blocks}\\t{' '.join(timings)}')\n")
                    tester.chmod(0o755)
                    destination = root / f'trial-{case}'
                    result = subprocess.run([sys.executable, '-O', '-B', '-c', code,
                                             str(tester), str(destination)], capture_output=True)
                    self.assertEqual(result.returncode == 0, passed, result.stderr.decode())
                    self.assertEqual(destination.with_suffix('.json').exists(), passed)

    def test_numerical_comparison_requires_explicit_matching_nonfinite_values(self):
        Path('.work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.work') as directory:
            reference, rewrite = (Path(directory) / name for name in ('reference.tsv', 'rewrite.tsv'))
            for value, other, allowed in (('inf', 'inf', True), ('-inf', '-inf', True),
                                          ('nan', 'nan', True), ('inf', '-inf', False),
                                          ('nan', 'inf', False), ('inf', '2', False)):
                reference.write_text(f'1\tBirthday\t{value}\t3\t0.5\n')
                rewrite.write_text(f'1\tBirthday\t{other}\t3\t0.5\n')
                for options in ([], ['--nonfinite']):
                    with self.subTest(value=value, other=other, options=options):
                        result = subprocess.run([sys.executable, '-O', '-B', 'test/compare_values.py',
                                                 *options, str(reference), str(rewrite)], capture_output=True)
                        self.assertEqual(result.returncode == 0, bool(options) and allowed,
                                         result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
