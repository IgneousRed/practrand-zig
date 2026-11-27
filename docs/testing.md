# Testing

Run commands from the repository root inside `./scripts/dev bash`. Zig, Python,
Clang and SDK inputs come from the locked Nix environment, not host installations.
On Apple Silicon, the [native tool bundle](../nix/llvm23/README.md) supplies
LLVM/Clang 23.1.6 and rebuilt Python 3.15.2, requiring macOS 26 or later.
The shared native bundle pins Git 2.56.1 and Perl 5.44.0, and supplies the same
rebuilt Python for Git helpers. Its shared library recipes update compression,
TLS-adjacent and other support dependencies without replacing their provider roles.
Bash retains its catalog source and features while sharing Readline 8.3 patch 6.
Its verified compiler context uses SDK 14.4 headers and SDK 27 C++ link stubs.
The environment passes that same stub directory to Zig's Metal build.
The Linux recipe retains the shared catalog's Clang/LLVM 23.1.3 and Python 3.15.2.
Its package graph has been evaluated, but native Linux runtime and numerical
validation remain outstanding; it is not certified as the latest compatible
Linux toolchain. Zig retains its own pinned backend; upgrading Clang does not
replace that embedded toolchain.
The selected Zig binary still retains older LLD, libc++ and compiler-rt runtime
packages. They remain dependencies of Zig, separate from the native compiler and
rebuilt Python closures. The refreshed Git/Python bundle uses the same
published native recipes and realized outputs as compatible consumers. Bootstrap
compiler and SDK support inputs have separate roles; they are not substitutes
for Zig's runtime backend. Historical captures keep their recorded environments.
Check dependency updates before every commit with `scripts/check-deps`; report
new versions without changing locks implicitly. An unavailable update source
fails the check. Explicit reference builds also require the locked archive tools. New reference
executables use fresh destinations and retain their environment; their library
cache identity includes the full environment store path.
Reference builds and source checks explicitly include the standard math and
allocation headers required by upstream headers, preserving frozen driver bytes.
The unchanged official reference used for explicit baseline capture is in
the lazily acquired `.vendor/PractRand` view; see [provenance](reference-source.md).
The dependency checker prefers the rebuilt interpreter when it is already
registered in Nix; otherwise it obtains only the public bootstrap Python.
A successful report switches its cache root; failed reports retain the prior root.

For environment evaluation without building dependencies, use the launcher's
declared-input staging:

```sh
./scripts/dev --eval packages.aarch64-darwin.dev-environment.drvPath --raw --option allow-import-from-derivation false
```

Select the supported host attribute needed. Avoid direct flake references to a
populated checkout: they can copy ignored captures and environments into the store.

## Run-specific build caches

Use `python3 -B tools/zig_run.py` in place of `zig` for the build/test commands
below. The helper runs Zig from the repository root with a fresh local cache at
`.work/zig-run-*/zig-cache` and removes it on success, failure, or interruption.
Installed executables, logs, comparison captures, and the global Zig cache remain.
Remove the run-local cache immediately after its last consumer, including failed
or interrupted runs; remove checkout `.zig-cache` too if used. Preserve source,
logs, results, the shared global cache and other runs' caches.
Direct Zig invocations must supply and clean their own run-specific `--cache-dir`.

## Full test suite

```sh
python3 -B tools/zig_run.py build test -Doptimize=ReleaseFast
```

Run `scripts/pre-commit` before every commit. It
runs the read-only dependency update check first, then this suite in a fresh
retained run directory with its own Nix environment root. It runs the Zig and Python checks and fresh SFC16, SFC32 and SFC64
comparisons in both result modes against the durable original-reference fixtures.
Every rewrite run executes through 2^32 bytes (4 GiB), reporting all 23
power-of-two checkpoints from 1 KiB. The default CPU execution mode is used.
A failed check, missing fixture or unavailable prerequisite fails the command.
`test-unit` is partial validation, not a substitute for this full suite.
Additional build options can be passed through, for example
`scripts/pre-commit -j2` to bound build concurrency.

The rewrite is built directly from the current sources, independently of a
previously installed executable. Comparison captures are saved under
`.work/full-tests/parity/`; authoritative original results remain under
`test/reference-results/`. The full suite never builds or executes the original
tester and never regenerates reference fixtures. Longer reference captures are
an explicit operation described below.

For concurrent verification, select a separate capture directory with
`-Dtest-output=.work/RUN/parity`. The helper already isolates and cleans each
run's local cache. This changes only fresh comparison artifacts; it does not
change the durable fixture location or the six-case/4 GiB coverage.
Timing collected while other work is active is not performance evidence.

## Optional Vulkan checks

The default CPU environment excludes the SDK. The runner selects the
[pinned Vulkan environment](gpu.md#build-and-run) only for enabled Vulkan builds:

```sh
python3 -B tools/zig_run.py build test-gpu -Dvulkan=true
python3 -B tools/zig_run.py build test -Dvulkan=true -Doptimize=ReleaseFast
```

The first command runs focused hardware classification and executor checks. It
requires a real GPU and does not silently skip missing hardware. The second also
runs the complete ordinary suite, including all six fresh rewrite fixture comparisons.
With `-Dvulkan=true`, source checks additionally compile the maintained Vulkan C
backend with fatal warnings and compile/validate the shader. The normal CPU suite
needs no Vulkan dependencies. See [GPU ownership and coverage](gpu.md).

## Checks without long parity runs

```sh
python3 -B tools/zig_run.py build test-unit -Doptimize=ReleaseFast
```

`test-unit` includes `zig build check`: formatting of hand-maintained Zig files,
syntax parsing of maintained Python files, and Clang warning/compile checks for the SFC8
utility and all maintained C++ diagnostic drivers. C/C++ warnings fail the check;
upstream includes are treated as system sources and remain unchanged. Objects
are discarded; compile-only actions avoid injected Nix linker flags while keeping
all warning checks enabled. Imported
Zig observations retain their generator's compact format and are regenerated in
temporary storage and compared byte-for-byte by this same check.
No additional linter is configured. Use `python3 -B tools/zig_run.py build` for a Debug
development build.

The full/unit targets also run the [built-in RNG byte-vector checks](builtin-rngs.md#verification),
covering 732 retained original vectors, every active factory, names/native widths,
whole/irregular reads, seed parsing and unavailable catalog positions. They never
recapture those vectors. The generator adapter and its imported helper sources
are compiled as part of `check`; maintained adapter warnings are fatal. Native
adapter checks also verify that reseeding discards a buffered partial word.

They additionally check 71 retained [seeding vectors](seed-testing.md#verification-and-reference-provenance)
from an independent original-library driver, exhaustive small Gray cycles,
deterministic pass exhaustion and whole/irregular seeded reads. Bounded CLI
checks execute the freshly built tester in all seed-walk modes and result
policies, validating length units, option order, diagnostics and final-cycle
reporting. Five additional unchanged-original CLI captures check widths 7, 8 and
15, with exact displayed rows in reference-compatible mode; native width parsing
and tiny-width initialization are checked separately. For focused generator and
seed tests, use
`python3 -B tools/zig_run.py build test-seed -Doptimize=ReleaseFast`.
These checks never recapture fixtures.

The local `binarymult16` and `fibmulmix16` adapters define their unsigned
products while preserving the retained original byte vectors in both result
modes; see [UB053](upstream-bugs/UB053-binarymult16-signed-overflow.md) and
[UB055](upstream-bugs/UB055-fibmulmix16-signed-overflow.md). The ordinary vector
check exercises both whole and irregular reads, including buffered refills.
The broader [D028 remedies](departures-from-upstream.md#d028--defined-remaining-built-in-generator-arithmetic)
define the additional confirmed products and rotations while preserving original
byte fixtures. [D029](departures-from-upstream.md#d029--explicit-legacy-and-fixed-ranrot-generators)
defines the captured legacy Ranrot stream under the original names, with a
warning, and adds explicit `_fixed` names for the intended changing recurrence.
Both choices work in Debug and both result modes. ReleaseFast remains the
required full-suite configuration.

Entropy-target checks compare three retained original 1,027-byte vectors through
whole and irregular adapter reads. Bounded CLI cases cover target selection,
entropy-string and byte units, option order, both batteries/result policies,
folding, serial/threaded equivalence, original basic-check rejection, `1K`
strings (`8 KiB`), `arbee` through 32,768 strings (`262,144` bytes, past
`history_length = 16,384`) and direct `EntropyPoolingTester(...)` expressions
for `arbee` and `sha2_based_pool` under the rewrite's [D024](departures-from-upstream.md#d024--safe-entropy-pooling-history-insertion-bug-fix)
fix for [UB007](upstream-bugs/UB007-entropy-pool-crash.md).
See [entropy verification](entropy-testing.md#verification-and-reference-provenance).
For focused checks, use
`python3 -B tools/zig_run.py build test-entropy -Doptimize=ReleaseFast`.

Reporting checks compare all finished layouts (62 fixed cases per layout) and
the optional experimental metatest summary (26 checkpoint cases) against retained
original captures. They cover filtering, option order, checkpoint reset, both
result policies, full precision and independent failure stopping. Fixtures are
never regenerated; see [report verification](report-formats.md#verification).
For focused reporting checks, use
`python3 -B tools/zig_run.py build test-reports -Doptimize=ReleaseFast`.

Input checks also replay 85 original byte vectors and three entropy-wrapper
metadata cases, then compare direct file/nested-stdin CLI reports and EOF/error
handling. Six additional retained multi-reader/control vectors verify
original-order priming through whole and irregular reads. Their retained output
bytes independently check CLI reports in both result modes. Invalid-request
probes ensure no premature stdin reads, and descriptor probes check teardown
and failed priming cleanup. These use retained fixtures and a freshly linked
adapter probe; see [input verification](builtin-rngs.md#verification).
No reference build or capture runs in ordinary tests. `input-vectors.json`
keeps metadata-only upstream captures for entropy wrappers because untouched
0.96 retains UB007. For focused input
checks, use `python3 -B tools/zig_run.py build test-input -Doptimize=ReleaseFast`.

The Zig checks exercise the FPF, Birthday, NS3 and DC7 kernels individually,
compare Mod3 histograms with independently summed nine-symbol windows across
call and sampling boundaries, BCFN histograms with direct thirteen-sign windows,
and classified bytes/RNG progress with direct bit counting. The
[independent FPF/64 checks](fpf64-verification.md) compare exact aligned-window
histograms and 14 retained original single-call scoring rows. Run these alone
with `python3 -B tools/zig_run.py build test-fpf64 -Doptimize=ReleaseFast`.
Classification checks
cover all 64 bits per Arbee word, mixed tie-group widths, retained bits across
scalar/vector call boundaries, and identical generator progress for tie-heavy
and tie-free input. They also check Gap's
wrapping age thresholds and warmup failure, extreme-statistic probability
endpoints, and preservation of NaN samples for fatal result validation. The Birthday
check reuses a zero buffer for 16 GiB of logical input. Radix sorting is also
compared with comparison sort around its cutoff and across varying bit widths
and fixed high prefixes. Paired DC16/DC32 checks independently assemble windows
across odd word calls with counters seeded above 2^32. A small streaming oracle
also constructs core and Expanded stream owners, compares serial and parallel
counter/rolling/transform/random state over irregular logical calls, and checks
exact checkpoint results. That oracle supplies identical caller slices to both
paths; it does not cover different CLI batch partitions, including the inherited
[UB014 Pat5 consequence](upstream-bugs/UB014-pat5-batch-tail.md) disclosed in D006.
Counting-service checks cover ordered buffer reuse,
failure publication, and cleanup. Shared service checks cover independent progress
alongside the CPU pool, failure joining, reuse, and teardown without GPU hardware.
These are bounded correctness checks rather
than the long parity runs below. Python tests use saved text and fake
processes to check report normalization, identical input delivery, and detection
of an incomplete run or rejected input despite apparently complete reports.
Isolated [Arbee checks](arbee.md#reference-checks) compare seeding, reset, entropy
mixing, flushing, and wrapping against vectors from the unchanged upstream RNG.
The file-only [numerical comparator](../test/compare_values.py)
remains available for captured TSV rows.
Its input and comparison checks remain active under optimized Python (`-O`),
including mismatched names, checkpoints, values, nonfinite values, and row counts.
Nonfinite numerical rows require `--nonfinite`, which accepts only matching NaNs
or infinities with the same sign; default comparisons require finite values.

Additional isolated checks cover histogram slice ownership, empty stream owners,
failed cache publication, and executor reuse after a job failure. Python checks
verify frozen executable copies and preservation of both generated files when
permutation input is rejected. Internal state constraints are compiled only into
test builds and remain active with ReleaseFast; runtime input and numerical-error
handling are unchanged.

## Frozen job inputs and publication

Parity, benchmark, and NaN-audit batches copy the executables they need before
starting their first case. `runtime.json` (or `NAME-runtime.json` for a benchmark)
records original paths and SHA-256 checksums of the captured bytes. Temporary
executable copies are removed when the batch ends; text captures and manifests
remain at the existing output paths. Files from an earlier run can remain until
their case is overwritten; use the command's completion status when judging the
whole batch. The NaN audit captures calibration input
before starting cases. This freezes a batch against later executable replacement;
it does not snapshot the operating system or prevent concurrent writes to a shared
capture directory. Use separate output directories for concurrent runs.

The reference builder captures source/header inputs before compilation and
publishes complete archives and linked executables by atomic rename. Isolated
drivers resolve upstream headers and private source includes against that captured
tree, so the precision audit also uses frozen source. The importer
parses and stages both generated data files before replacing either; the two final
renames are individual filesystem operations, not a multi-file transaction.

For a local before/after performance experiment, capture the baseline before the
change and run the same command after it, using distinct names:

```sh
python3 -B tools/benchmark_optimizations.py --name before --source both
python3 -B tools/benchmark_optimizations.py --name after --source both
```

The benchmark uses the pinned `.work/vendor-validation/RNG_output` by default;
build it with the reference command below first. It builds private ReleaseFast
instrumented source copies, saves phase timing and reports under
`.work/optimizations/results/`, and never edits normal sources. Compare shared
input prefixes, keep trials sequential, and repeat measurements before making a
performance claim. `--seconds`, `--source`, and `--output` allow focused studies.
New Nix benchmark jobs use a fresh `--name`; each retains an indirect environment
GC root and records its store identity. Historical jobs are not retrofitted.
Removing source modules requires a fresh `--build-dir` or a new `--name`.
Reused build directories reject stale Zig source copies before changing captured
sources or compiling, so removed imports cannot resolve against an old snapshot.

For Expanded SFC16 with maximum folding and all eight logical CPUs on the study
machine:

```sh
python3 -B tools/benchmark_optimizations.py --name expanded-sfc16 \
  --source sfc16 --battery expanded --threads 8
```

`--battery` defaults to `core`; `--source both` still means SFC8 and SFC64.
`--threads` overrides the worker limit only in a private source build, bounded
by available CPUs. It cannot be combined with the executable argument and does not change
the normal executable's default. Private builds use a monotonic clock and retain
the source's fixed OddPhi classification seed, recording its value in the trial
JSON. Earlier performance studies used a private zero seed; compare classification
values only between runs with the same seed. Provided executables retain their own
clock, worker settings, and auxiliary seed behavior. The stop is the first **completed** power-of-two
checkpoint strictly after `--seconds` (60 by default), including all intervening
reports from 1 KiB. Compare identical byte prefixes even when the stop checkpoint
moves. For overlapping input, private feed counters measure the counting
service and read counters measure reader calls; these durations overlap and must
not be added to infer elapsed time. Checkpoint counters remain cumulative time
inside completed reports. No such counters exist in normal executables.
Source-instrumentation checks and rejection of timing counters that disagree with
the reported checkpoint remain active under optimized Python (`-O`). Phase times
must also be finite and nonnegative, with positive elapsed time, before a
measurement is accepted.

## Isolated upstream NaN audit

This is a manual numerical audit of individual original tests and helpers. It
does not construct a full battery, compare rewrite reports, or add parity input
cases. It is excluded from ordinary unit-test discovery.

```sh
python3 -B tools/build_reference.py --driver test/upstream_nan.cpp \
  --output .work/nan-audit/upstream-nan
python3 -B test/audit_upstream_nan.py
```

The [driver](../test/upstream_nan.cpp) selects one of 36 implemented upstream
classes per process. The [runner](../test/audit_upstream_nan.py) saves 182
stream/empty-state cases, scalar probes, calibration probes, stderr, and a JSON
summary under `.work/nan-audit/run/`. It uses two processes concurrently and a
60-second limit per case. Coup32 alone allocates a 512 MiB bitmap; the broad
manual audit consequently needs substantially more memory than scalar probes.
Exit zero means the audit finished, including captured upstream errors; it does
not mean the original code is free of NaNs. A timeout or invocation error marks
the audit incomplete. All observed statuses and last checkpoints remain in the
summary. The findings and limits are maintained in the
[upstream bug record](nan-audit.md).

Individual reproductions use `CLASS FIXTURE BLOCKS INCLUDE_EMPTY`, where each
block is 1 KiB; checkpoints are powers of two plus the specified final size:

```sh
.work/nan-audit/upstream-nan NearSeq3 zero 2 0
.work/nan-audit/upstream-nan DistC7 zero 4 0
.work/nan-audit/upstream-nan Gap16 random 2816 0
.work/nan-audit/upstream-nan BCFN_FF ones 4 0
.work/nan-audit/upstream-nan LimitedBigGapPrototype ones 64 0
.work/nan-audit/upstream-nan CoupGap zero 256 0
.work/nan-audit/upstream-nan Coup32 zero 1 0
.work/nan-audit/upstream-nan SimpleClassifyWord empty 0 1
.work/nan-audit/upstream-nan math
```

A NaN row contains byte count, name, upstream result type, raw value, processed
value, p-value, suspicion, and `NAN`. `invalid` records a floating-point invalid
flag raised during `get_results`; that flag alone does not prove an emitted NaN.
Upstream assertions can terminate a probe before its result row is appended.

## Reference-compatible results

`RNG_test stdin64 --reference-compatible ...` selects the PractRand 0.96 result
contract. Identical input bytes, checkpoints, folding, battery and auxiliary
randomness must reproduce the reference's statistical results, subject to the
accepted corrections linked below. Ordering, identifying banners, elapsed time,
diagnostics, input buffering, execution resources and equivalent optimizations
can differ. The banner identifies the selected contract. The supported feature
subset remains the same in both modes.

The default uses the [documented numerical improvements](numerical-policy.md).
Reference mode retains its previous expressions, sum order, probability tables and
target-dependent intermediate types. The immutable run policy reaches preparation
and scoring, including folded and classified results. The ordinary report format
remains unchanged; `--full-precision` appends diagnostic round-trip values when
explicitly requested. Independent scalar controls and reference-policy checks are
described in the numerical policy.

Focused controls cover FPF nominal totals without renormalization, Gap geometric
bin probabilities, Birthday residuals above 2^53, centered rarity with both unit
and non-unit models, NearSeq3 binomial moments, compensated scaling, and local
calibration interpolation fractions. Serial/parallel state comparison includes
BRank's low accumulator component. Further controls cover Hamming log-CDFs and
NearSeq3 sample/pair scores beyond probability underflow, Poisson midpoint tails,
report selection at rounding boundaries, and a normal-tail kernel checked against
41 independent controls and a 16,384-point monotonicity grid. The scalar
portability probe has 24 cases;
it supplements the full comparisons and does not replace native Linux execution.

Further default-only changes to valid finite results must preserve the reference
calculation under the flag and add independent checks for the improved answer.
Select policy outside hot counting loops where possible; do not fork whole
batteries merely to choose a numerical expression.

The explicit current result exceptions are:

- [FPF/64 sampling](departures-from-upstream.md#d010--fpf64-checkpoint-independent-sampling-bug-fix):
  values and available subtests may differ. Its isolated kernel oracle remains
  required. Other FPF strides are compared normally.
- [C8 seeding](departures-from-upstream.md#d017--fixed-c8-seed) and
  [complete tie-word use](departures-from-upstream.md#d018--c8-uses-every-arbee-output-bit):
  both are applied to the diagnostic original too, so C8 rows and values are
  fully compared with the saved fixtures.
- [Gap endpoint rounding](departures-from-upstream.md#d008--gap-16c-non-finite-reference-result)
  and [NS3/DC7 extreme endpoints](departures-from-upstream.md#d012--bad-rng-results-preserve-tail-endpoints):
  retain the accepted corrections and their focused numerical checks. These
  do not authorize ignoring arbitrary finite differences. An upstream abort
  cannot supply a successful checkpoint fixture.

Error handling, monotonic timing and checked output remain corrected in both
modes. These are not exemptions from comparing valid statistical results.
[Measured floating-point differences](departures-from-upstream.md#d003--floating-point-equivalence-has-a-tolerance)
remain relevant across architectures; internal binary64 bit identity is not
promised. Ordinary displayed rows are compared exactly, so a visible difference
requires investigation rather than a broad tolerance increase.

## Compare the durable fixtures

```sh
python3 -B tools/zig_run.py build -Doptimize=ReleaseFast
python3 -B test/compare_fixtures.py
```

The three inputs use normal original SFC16/32/64 initialization with seed zero.
The standalone native [`sfc_stream.c`](../test/sfc_stream.c) is independent of the
tester. Original 1 MiB prefix hashes in the reference's `input-prefixes.json`
record verify its seed, warmup, recurrence and little-endian byte order.
It emits bounded streams without
saving large input files. Each case executes fresh with and without
`--reference-compatible`, using Expanded, extra folding, `-a`, `-tlmin 1K`,
`-tlmaxonly`, and the same byte limit. SHA-256 hashes verify that both modes
receive identical full input. Executables are frozen before comparisons begin.

The comparator requires every fixture and every rewrite checkpoint through the
requested limit. It checks clean exit statuses and stderr, full input delivery,
flush failures, exact checkpoint sequences and unique test names. Rows are
matched by name; C8 values are included. Only corrected FPF/64 values and
available subtests are excluded, with their independent kernel check retained.
Missing or changed ordinary rows fail, including classification rows. Full report
text and numerical fixture data remain available for investigating a mismatch.

The routine limit is 4 GiB per generator and mode. The accepted reference extends
through 256 GiB per generator; pass `--last-exponent 38` to compare that complete
retained span explicitly. Requests for missing later checkpoints fail rather than
reducing coverage or regenerating a baseline. The retained reference size does
not add a 256 GiB workload to every commit.
`--fixtures FILE`, `--rewrite`, and `--output` select alternative artifact paths.
Results and diffs go under `.work/fixture-comparison/` by default.

The earlier `test/compare_reference.py` remains a manual historical diagnostic
for the unchanged original's SFC8/SFC64 comparison and disposable JSON cache.
It has the older C8 name-only exclusions and is not the full-test target or the
source of the new comparison fixtures. Its cached files under `.work/` may be
recreated; the repository fixtures described here must be preserved.

## Durable SFC reference fixtures

The seed-matched original SFC captures are retained in the single
[`test/reference-results/practrand-0.96.json`](../test/reference-results/practrand-0.96.json)
file, independent of the disposable original-result cache above. Its
`format_version: 1` document concatenates the original JSON objects in a `records`
map keyed by their historical relative filenames. The 97 records include all 87
completed checkpoints: every power of two from 2^10 through 2^38 bytes for SFC16,
SFC32 and SFC64, plus provenance, input hashes, run/attempt records and acceptance.
Each original record can be reconstructed byte-for-byte with two-space JSON
indentation and a final newline. No reports or numerical values were regenerated.

The embedded `summary.json` records the accepted scope, original checkpoint
checksums, and capture interruption. Loading requires an accepted summary and
an exact match between its checkpoint manifest and retained checkpoint records.
Every retained checkpoint hash is verified before any reports are compared,
including checkpoints beyond the requested test limit. Missing acceptance or
checksum data fails rather than disabling integrity verification.

The original attempt targeted 2^40 bytes, but a host restart interrupted all three
runs after their 256 GiB checkpoints. On November 7, 2026 the user accepted that
retained span and declined a replay. Per-case `run.json` records the interruption;
the original attempt records and original 1 TiB arguments remain preserved. The
accepted reference does not claim successful execution through 1 TiB. JSON output
does not contain the live statistical state needed to continue after a restart.

Reproduction is an explicit long-running operation, excluded from the full suite:

```sh
python3 -B tools/capture_reference.py --output .work/reference-reproduction --last-exponent 38
python3 -B tools/reference_fixtures.py .work/reference-reproduction .work/reference-reproduction.json
```

The capture uses original 0.96's built-in SFC16, SFC32 and SFC64 with seed zero
and their normal `seed()` warmup. Three single-threaded cases run concurrently,
using Expanded, extra folding and full reports at every power of two from 2^10
through the selected limit. The default reproduction limit is 2^38 bytes.
Ordinary statistical failures do not stop a case. Capture staging stays under
`.work/`; the second command concatenates all staged JSON records into one fresh
file and refuses to replace an existing output. A new capture must be reviewed
and its summary explicitly accepted with checkpoint hashes before it can be used
by the fixture comparator. Concatenation does not grant acceptance.
New captures root the locked environment alongside their output and frozen build
inputs. Resuming a new capture checks that environment identity; older captures
retain their recorded contract without retrofitting Nix metadata. Roots remain
until the corresponding retained data is deliberately retired.
The capture destination must be fresh;
use `--output DIRECTORY` to reproduce without replacing retained fixtures.
`--resume` restarts cases whose last attempt recorded `capture_failed`, using
the recorded executable. It retains
the prior attempt and verifies repeated checkpoint values and report text
(excluding time) before adding later checkpoints. Retained checkpoint files are
never replaced by a resumed capture. Completed or upstream-failed cases are kept.
Finalized accepted references cannot be resumed; reproduce into a fresh output
directory instead. The temporary build used for the retained attempt was removed
after acceptance. Its source hashes, diagnostic patch and compiler identity remain
in the embedded `provenance.json` record; its recorded build paths are historical,
not dependencies of fixture loading or ordinary tests.

The vendored release stays unchanged. A private copy under `.work/` changes each
classification transform's Arbee seed to OddPhi with zero high word, preserving
the original auxiliary RNG draw. It also consumes all 64 tie bits, low byte first,
matching [D018](departures-from-upstream.md#d018--c8-uses-every-arbee-output-bit).
Original calls contain whole 1 KiB blocks, so every call exhausts complete tie
words. Observer statements emit the already-computed results and an end marker
after each completed report. Other original statistical calculations, result
validation and FPF/64 alignment remain.

Before long captures, repeated SFC16 runs through 16 KiB check deterministic
full-precision results including classification. An observer-disabled run checks
that the displayed reports match after removing elapsed time. A separate byte
probe compares the modified original with the rewrite across five input patterns,
whole and irregular calls, the original 16 MiB recursion boundary, and subsequent
Arbee output. `provenance.json` records
source hashes, the complete diagnostic patch, executable/compiler identity,
configuration and these checks. During capture, each generator has a `run.json`
status record and one atomically published JSON file per completed checkpoint.
These staging files become embedded records when concatenated. Checkpoints retain
full-precision raw/processed values, p-values, suspicion, original
normalized weights and report text. Nonfinite values use JSON strings.

An upstream error preserves all completed checkpoints and records its exit code,
stderr and unfinished report in `run.json`; an unfinished checkpoint is never
published as a completed fixture. Raw diagnostic streams and frozen build inputs
remain disposable outputs under `.work/`. Preserve specifically needed evidence at its
approved visibility before finishing; a running capture does not establish
that later checkpoint fixtures exist or that the full test target has passed.

## Order of results within a checkpoint

Upstream preserves the order in which results are appended. The
test manager (`.vendor/PractRand/tools/TestManager.h`) ([source acquisition](reference-source.md)) visits tests in battery-list
order; each test appends its available subresults in its own implementation order.
Transforms (`.vendor/PractRand/src/tests_other.cpp`) ([source acquisition](reference-source.md)) visit child tests in order,
so transformed groups are traversed recursively. The original stream precedes
folded streams in the battery construction (`.vendor/PractRand/src/test_batteries.cpp`) ([source acquisition](reference-source.md)).

The reporter (`.vendor/PractRand/tools/RNG_test.cpp`) ([source acquisition](reference-source.md)) filters this result vector
and prints selected indices in increasing order. It does not sort by p-value,
severity, raw score, or test name. Parallel execution uses the same result
collection order. With `-a`, every result produced at that checkpoint is shown;
short-input guards can still omit unavailable subtests.

The rewrite intentionally sorts selected rows by full displayed test name in
ascending, case-sensitive byte order, including transform prefixes and subtest
suffixes. Test names are unique within a checkpoint; stable sorting is not
required. The comparison matches rows by name within each checkpoint; see
[D013](departures-from-upstream.md#d013--reports-sorted-by-test-name).

## Regenerate imported data without running a battery

```sh
python3 -B tools/import_calibration.py .vendor/PractRand/src/tests_core.cpp \
  --output .work/vendor-validation/calibration_data.zig \
  --permutation-output .work/vendor-validation/permutation_data.zig
cmp src/calibration_data.zig .work/vendor-validation/calibration_data.zig
cmp src/permutation_data.zig .work/vendor-validation/permutation_data.zig
```

These checks do not establish every numerical tail or platform. See
[departures](departures-from-upstream.md) and [upstream bugs](upstream-bugs/README.md)
for known behavior and limits. Historical studies are retained locally.

## Original precision audit

The [operation-level audit](precision-audit.md) documents the manual scalar
probe, numerical controls, known failures, and runtime coverage limits.

For the native Metal backend on macOS, run
`python3 -B tools/zig_run.py build test-gpu -Dmetal=true -Doptimize=ReleaseFast`;
no Vulkan SDK is needed.
This checks exact state, every FPF exponent, concurrent owner
leases, failure/reuse and complete logical calls on real hardware. The ordinary
[full test command](#full-test-suite) remains required for CPU/Python/reference coverage.
Hardware checks establish correctness, not throughput.

Frozen GPU runtimes use the [shared immutable Vulkan library pool](gpu.md#shared-frozen-vulkan-libraries).
The focused helper tests run with
`python3 -B -m unittest discover -s test -p test_pool_vulkan.py`.

## November 22 built-in arithmetic audit

The bounded native ARM64 macOS Debug CLI audit exercised all 732 retained seeded
cases through 4 KiB. Before D029, the D028 remedies left four cases for
`ranrot_var32`/`ranrot_var64` aborting. Their direct rotation correction changes
the frozen original sequence; [UB070](upstream-bugs/UB070-ranrot-zero-rotation.md)
records that compatibility boundary and the accepted separate-name remedy.

After D029, the Debug unit/check and CLI target passes, including all 732
unchanged original generator vectors and the four new fixed-generator controls.
The fixed controls cover 65,539 bytes for both widths and both seeds, with whole
and irregular reads. Independently, a fatal-UBSan build of the actual adapters
agrees with Python integer arithmetic on 160 boundary cases (655,360 words),
including positions 0/1/24/44/45 and both counter wraps. Every legacy boundary
case also matches the untouched optimized original's output and final state.
These checks do not claim the long SFC comparisons were run in Debug.

The full CPU ReleaseFast suite passed source, Zig, Python and CLI checks plus
all six fresh SFC16/32/64 comparisons through 4 GiB in both result modes. Forty-four
affected non-Ranrot original fixture cases also matched fresh optimized-original
output and the actual adapters under fatal UBSan, using whole and irregular reads
and matching metadata. Independent Python integer controls checked 4,243,456
rotation cases across 8/16/32/64-bit widths. Existing original fixtures, comparison
rules and vendor sources were unchanged. The final D029 full ReleaseFast run
also passes all 21 build steps, 86 Zig tests, Python/CLI checks and all six fresh
4 GiB comparisons. Its installed CPU executable passes nine relocated CLI runs
with only `PATH=/usr/bin:/bin` and links only the system runtime.
Historical validation used isolated run-local caches. The maintained byte fixtures
and reproduction commands above are the public verification inputs.
This bounded audit does not prove every state or target platform is free of
undefined arithmetic.
