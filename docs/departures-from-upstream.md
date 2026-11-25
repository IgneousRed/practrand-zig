# User-visible departures from original PractRand

Update this note in the same change as every departure that can affect a user.
The reference is untouched PractRand 0.96; see [reference provenance](reference-source.md) and [testing](testing.md).

Record changed commands, defaults, supported features, input interpretation,
results, reports, stopping, errors, platform support, or resource requirements.
For each departure give the upstream behavior, our behavior, its status, the
reason, and verification. Missing upstream features count as compatibility gaps.

Do not record internal architecture, data structures, algorithms, or how we obtain
equivalent results. Development guidance belongs in [contributor guidance](contributing.md).
Performance claims need measurements of comparable work and inputs.

Known and suspected issues in the original are maintained in
[the upstream bug log](upstream-bugs/README.md); this file records user-visible rewrite
differences.

## D001 — Supported feature subset

**Status:** Present in 0.1.0; compatibility work remains.

Original 0.96 provides multiple batteries, folding modes, RNG and input expressions,
seeding/entropy targets, threading, report formats, metatests, and control commands.

This version supports the complete core (`-te 0`) and Expanded (`-te 1`) batteries, unknown/8/16/32/64-bit
stdin, direct files and the active built-in RNG/expression factories, raw/standard/extra folding
(`-tf 0/1/2`), serial and parallel execution, byte- and time-based checkpoints,
narrow/wide/scoring reports, filtering, failure stopping, hexadecimal RNG seeds,
unseedable-input seed labels, native seed testing and entropy-pooling testing (`-ttep`).
The defaults are core, standard folding, minimum 2 seconds, and maximum 32 TiB,
following the upstream source.

The special Birthday and experimental batteries are intentionally omitted, with
no plans to implement them; see [D021](#d021--special-and-experimental-batteries-intentionally-omitted).
The unfinished upstream alternative report table and self-test commands are
rejected explicitly. RNG and stream
transformation expressions, special wrapper factories and the original
recommended/reference catalog listing commands are supported. Upstream startup
self-tests and the runtime `--self_test`/`--selftest` commands are intentionally
omitted and unplanned. `-no_selftest` and the original `-skip_selftest` are
accepted as no-ops. Developer checks use the
[full test target](testing.md#full-test-suite).

**Reason:** Deliver a usable core-battery milestone while keeping unsupported
requests visible. **Verification:** Differential CLI/report cases and the
explicit unsupported-option checks described in validation.
See TODO.md for remaining work.

The finished upstream reporting layouts are supported through `-table_narrow`,
`-table_wide` and `-table_scoring`, with narrow as the default. Weight and score
columns follow the original rendering, including rounding and saturation.
`--full-precision` works in each layout. The original `-table_alternative` leaves
numerical p-values blank behind a TODO and remains unsupported; completing that
format would introduce behavior absent from the pinned reference. Verification
compares 62 fixed cases in each supported layout against durable captures from
the unchanged original formatter; see [report formats](report-formats.md).

The optional experimental metatest summary is supported through `-do_metatest`
and `-no_metatest`, disabled by default as upstream. Each checkpoint combines
only selected rows' positive scores as `sqrt(sum(score * score))`, with the
original evaluation thresholds and one-decimal rendering. Accumulation retains
upstream result order before presentation sorting. The summary does not control
failure stopping. Both arithmetic modes retain their existing result calculations
and report filtering. Verification compares 26 fixed checkpoint cases against
durable captures from the unchanged original reporter; see
[metatest behavior and limits](report-formats.md#experimental-metatest-summary).

The built-in RNG gap was closed on November 12, 2026 for all 284 registered
factories in the original recommended, research, candidate, transform and catalog
registries, including `dummy_rng`. Explicit seeds use the original 128-bit
hexadecimal convention and `seed(low64, high64)` semantics. Omitted RNG seeds use
a random 32-bit value, printed for replay; failure to obtain OS entropy is an
error. Stdin labels and fixed C8 auxiliary randomness retain D017. Pure RNG
expressions and aliases work. The remaining ten stdin/file factories and three
special wrappers were added on November 21, 2026; their lifecycle differences
are recorded in D023 below. Original recommended
catalog names and all 27 positions remain unchanged; the six removed generators
fail with an explicit no-longer-supported diagnostic as agreed in
[UB002](upstream-bugs/UB002-removed-rng-catalog.md). `--list-rngs` additionally lists
registered factories and labels removed entries. The retained 732 original byte
vectors cover every active factory and every active catalog expression, with
ordinary and mixed 128-bit seeds and whole/irregular fill calls. See
[built-in RNG usage and verification](builtin-rngs.md).

The extra-folding gap was closed on October 30, 2026: `-tf 2` now selects the
original stream and all nine upstream low-bit streams, preserving their report
prefixes. Report ordering is now described in D013. The default remains standard folding.

The entropy-target gap was closed on November 21, 2026. `-ttep` retains the
original entropy-capability requirement, three basic setup checks, HC256 replay
seed and fixed 57-byte `EntropyPool_MetaRNG` strings. Bare lengths and `K/M/...`
count strings; explicit `B` suffixes count output bytes. Each string produces eight
tested bytes, and reports label the log2 count as `entropy strings`. Setup
rejections use stderr/status one under D004. The rewrite fixes the original
wrapper's [UB007 iterator-decrement crash](upstream-bugs/UB007-entropy-pool-crash.md)
under [D024](#d024--safe-entropy-pooling-history-insertion-bug-fix); the target
does not bypass the original basic-check rejection observed for `sha2_based_pool`.
Three repeated original byte vectors and CLI/probe comparisons establish the
verified scope in [entropy testing](entropy-testing.md).

The threading gap was closed on October 31, 2026. `-multithreaded` is the
default. Its counting threads include the caller and are bounded by the available
CPU count. Paired Vulkan counters also bound the pool by the number of family
jobs across top-level streams. Other GPU configurations use up to eight counting
threads and CPU-only execution uses up to four. Threaded Expanded input overlap adds
one host thread for CPU input as described in D006;
GPU stdin and built-in generators use the reader described in D014. `-singlethreaded` selects serial execution. Reports retain their serial
order. Execution mode and input batching can nevertheless change Pat5 statistics
through inherited UB014; see [D006](#d006--measured-resource-use) for the observed
default-versus-default difference. Historical validation checked the measured effects.

The Expanded gap was closed on October 31, 2026. All original statistical
families and parameter variants run under `-te 1`, including `[C8]`, with raw,
standard, or extra folding. The classification transform's auxiliary seed is now
fixed as described in [D017](#d017--fixed-c8-seed), independently of stdin's
`-seed` label. The numerical limits remain documented in the
[reference contract](testing.md#reference-compatible-results).

## D027 — Reject one-byte entropy messages

**Status:** Intentional, approved November 22, 2026; both result modes.

Original `EntropyPoolingTester` accepts one-byte messages and can stall
indefinitely. Duplicate-seed rejection can cover the entire seed space, leaving
no acceptable next seed. The rewrite rejects that effective message size before
creating the child RNG, reports the reason on stderr, and exits with status one.
Nested expressions use the same check. The original MIN/MAX parsing remains:
MIN supplies both bounds, so requesting MIN=1 and a larger MAX is also rejected.
The native `-ttep` target uses 57-byte strings and is unaffected. The separate
native tiny seed-width acceptance and history behavior remain unchanged.

**Reason:** Give a predictable failure for the confirmed inherited
[UB054](upstream-bugs/UB054-entropy-history-exhaustion.md) stall without changing
the entropy walk. The compatibility cost includes rejecting short one-byte runs
that previously completed.
**Verification:** CLI checks exercise direct/nested expressions, inherited
numeric parsing and both result policies, reject before reading an open stdin
pipe, and run a two-byte control alongside existing eight/57-byte cases.

## D023 — Stream input lifecycle and errors

**Status:** Intentional, November 21, 2026; original stream and special-wrapper
expression choices are implemented.

Original 0.96 opens and reads stdin/file sources while constructing an expression,
uses 4 KiB native-word buffers and exits directly with status zero on exhaustion,
open failure or read failure. Its reader does not close owned files. The rewrite
opens and primes sources in expression-construction order after validating CLI
options and seeds, before wrapper seeding can read from any child. It keeps
the same native-word interpretation, complete-word EOF handling and 4 KiB nested
reader buffer. Owned files close during teardown; stdin is borrowed.

EOF keeps `error reading from file`, status zero and no padded/partial checkpoint.
Open failures and actual read failures produce status one, consistent with D004.
Error text can differ. EOF unwinds through the input owner; EOF and read errors
join any pending CPU counting update before returning or exiting. The existing direct-stdin path and early-stop
consumption difference in D007 remain. New stream expressions may also consume
unused bytes through their native buffers and transforms.

GPU statistical execution accepts these expressions, but reads expressions
containing streams on the caller rather than speculating on a producer thread;
a blocked nested read cannot use the direct descriptor reader's cancellation.
The input path does not select a different statistical model. Call-boundary-dependent
Pat5 differences between execution modes are documented in [D006](#d006--measured-resource-use).
Bounded 4 MiB input checks on Apple M2 matched reference-compatible,
full-precision reports for direct stdin, files and nested stdin on CPU, native
Metal, MoltenVK and KosmicKrisp. These checks establish the input paths on that
machine; broader GPU/platform coverage remains unvalidated.

The three special factories preserve upstream wrapper behavior, including the
[UB003 entropy bound parsing](upstream-bugs/UB003-entropy-wrapper-bounds.md),
except that `EntropyPoolingTester` and native `-ttep` both fix the
[UB007 iterator-decrement crash](upstream-bugs/UB007-entropy-pool-crash.md)
under [D024](#d024--safe-entropy-pooling-history-insertion-bug-fix). Native
`-ttep` selects the separate target workflow described in
[D001](#d001--supported-feature-subset).

**Reason:** Complete the original input choices while retaining owned-resource
cleanup, CLI validation and detectable I/O errors.
**Compatibility restoration:** Original-order priming restores the assignment of
initial 4 KiB chunks to multiple readers sharing stdin, including wrappers that
read during seeding. Invalid requests still reject before priming. The adapter
owns the reader resources independently of imported wrappers' child ownership.
See audit finding 4 for the original
first-use mismatch and its correction.
**Verification:** 85 existing original byte captures, six additional multi-reader
and control vectors, plus three wrapper metadata
captures; whole/irregular adapter reads; file/nested-stdin report comparisons;
short input, invalid expressions/options, free-form labels, open/read errors.
Multi-reader reports compare with retained original output bytes in both result
modes. Descriptor checks cover teardown and failed priming after an earlier
file has opened.
See [input usage and verification](builtin-rngs.md).

## D021 — Special and experimental batteries intentionally omitted

**Status:** Intentional, November 21, 2026. Neither battery is planned for implementation.

Original PractRand 0.96 provides two additional battery selections:

1. Special Birthday (`-te 10`) selects `Birthday64`, a specialized Birthday
   Spacings test. It needs 200 complete 64 MiB buffers (12.5 GiB per instance)
   before reporting. Our [upstream audit](nan-audit.md) did not reach that
   threshold, so end-to-end reporting remains unverified by this project.
   Its help also describes a different test; see
   [UB008c](upstream-bugs/UB008c-birthday-suite-help.md).
2. Experimental (`-te 20`) selects `LimitedBigGapPrototype`. It can produce
   results, but has confirmed NaN failures on all-ones input; see
   [UB004](upstream-bugs/UB004-bad-rng-nan.md#bad-input-empty-histograms-in-experimental-tests).

The rewrite rejects both selections with the unsupported-battery diagnostic.
These omissions are an agreed scope decision. Core (`-te 0`) and Expanded (`-te 1`)
retain their existing Birthday tests.

**Reason:** Keep the supported battery scope at core and Expanded; neither of
these specialized/prototype selections is planned for end-user support.
**Verification:** Source inspection confirms the original selections in
`RNG_test.cpp` (`.vendor/PractRand/tools/RNG_test.cpp`) ([source acquisition](reference-source.md)) and the rewrite's explicit
rejection of selections other than 0 and 1 in [`main.zig`](../src/main.zig).
This records the existing behavior and the implementation-scope decision.

## D022 — Seed testing and additional deterministic walks

**Status:** Original seed target implemented; additional walks intentional,
November 21, 2026.

`-ttseed[BITS]` now uses the unchanged original `FastSeeder128_MetaRNG` by default:
HC256-selected seed mutations, recent-hash avoidance, and one target `raw64()`
after each original `seed(low, high)`. Explicit widths, omitted-width metadata,
seed-count lengths and checkpoint labels follow 0.96. The metadata formula's
latent low-word error remains preserved in [UB050](upstream-bugs/UB050-seed-width-autodetection.md).
Stdin/nonseedable sources are rejected rather than pretending to reseed them.

`--seed-walk gray` and `--seed-walk balanced-gray` add deterministic exhaustive
passes. Both change exactly one seed bit per sample; the latter approximately
balances full-cycle flip counts within 14% of their mean. Balanced widths are
16/32/64/128. `-seed` translates deterministic seeds by XOR; original mode retains
its HC256 replay-seed interpretation. Additional modes stop after one complete
pass and report its final checkpoint, including when a larger limit was requested.
The banner and RNG name identify the selected mode. These additions remain
available under `--reference-compatible`, which chooses result arithmetic.

**Reason:** Preserve original initialization testing while adding reproducible
coverage of every seed and broader early high-bit exercise.
The native original walk preserves 0.96's suffix conversion and negative-only
width rejection, including its acceptance below 16 and tiny-space stall.
The expression factory retains its distinct 16–128 bounds; see
[UB052](upstream-bugs/UB052-seed-width-validation.md). Only the additional Gray
walks enforce 16–128 at the native target boundary.
**Verification:** 71 independent original-library byte vectors, whole/irregular
fills, exhaustive small cycles, cycle exhaustion, bounded CLI checks and the
ordinary suite. See [seed testing](seed-testing.md) for commands, limits, proof
outline and fixture provenance. No throughput claim or every-window balance
guarantee is made.

## D019 — Reference-compatible result setting

**Status:** Intentional, November 7, 2026.

`--reference-compatible` selects the PractRand 0.96 statistical-result contract,
with the accepted FPF/64, C8 and numerical-error corrections. The identifying
banner records this selection. Original PractRand has no corresponding option.
The improved experience remains the default. The G-test and DC7 accuracy
improvements in [D020](#d020--stable-default-g-test-and-dc7-tails) apply only to
that default; this flag retains the preceding reference calculations. The other
accepted corrections remain shared. Future improvements that change valid finite
results must preserve this reference calculation or become an agreed correction.

Sorting, corrected timing/errors/output handling and equivalent CPU/GPU
optimizations remain available. The supported feature subset is unchanged.
The [reference contract](testing.md#reference-compatible-results) defines the
precise permitted differences and comparison coverage without duplicating them
here. Its diagnostic original uses the same fixed C8 seed and complete tie words.

**Reason:** Keep original results useful for finding rewrite bugs while allowing
the default experience to improve. **Verification:** The full test target runs
fresh SFC16/32/64 cases in both modes against durable JSON fixtures, fully checking
C8 and retaining the separate corrected FPF/64 kernel oracle. Fixtures through
the requested test limit are required; a running capture is not a full-suite pass.

## D020 — Stable default G-test and DC7 tails

**Status:** Intentional default-only improvements in 0.2.0, November 12–13, 2026.

Default mode uses centered G-test evaluation, compensated sums, retained BRank/DC7
log tails, stable near-neutral score conversion and Birthday log-tail arithmetic,
integer-first permutation probabilities, and improved Hamming underflow handling.
It also centers FPF's overall nominal-count statistic and rarity count residuals,
uses stable Gap bin probabilities, preserves Birthday's integer difference in raw
scores and branch selection, compensates NearSeq3/BRank accumulation, and retains
calibration's local interpolation fraction through a final fused multiply-add.
NearSeq3 also retains logarithmic Hamming tails beyond probability underflow;
normal suspicion uses a pure-Zig rational/log-tail kernel; Birthday computes
small-lambda midpoint probabilities from the smaller tail with compensated
recurrence. Improved report filtering uses direct tails or retained suspicion,
including comparisons at supported CLI threshold boundaries. Reference filtering
and CLI threshold limits remain unchanged.
Gap startup normalization now preserves retained mass and its model residual;
BCFN constructs effective-width Bernoulli probabilities directly; NearSeq uses
scaled conditional probabilities below the normal CDF range; moderate G-test
deviances use a convergent centered series. Reference formulas and NearSeq
threshold selection/exhaustion remain unchanged.
DC7 also retains finite combined suspicion when two near-unit component
probabilities make the combined chi-square statistic underflow.
The [numerical policy](numerical-policy.md) describes the algorithms, independent
controls and linked upstream issue records. G-test preserves the represented
model's normalization residual; it does not renormalize probabilities or clamp a
negative result caused by an over-normalized model.

Improved statistical arithmetic uses binary64 on all targets, including G-test and
Hamming intermediates formerly widened on x86-64. Compensated sums recover small
addends without relying on the platform's long-double format. This trades implicit
x86 extra precision for an explicit common arithmetic policy. It does not promise
bit-identical platform transcendental functions. Builds and tests use the locked
Nix toolchain without a host-compiler fallback; approved lock updates are validated by
the numerical and reference checks using that compiler.

Raw statistics, processed scores, displayed probabilities, evaluations and failure
stops can differ. `--reference-compatible` retains the prior expressions, summation
order and probability-table construction, including target-dependent intermediates
and finite cancellation. Existing accepted NaN/infinity and Gap/FPF/C8 corrections
still apply in both modes; see the [reference contract](testing.md#reference-compatible-results).
Calibration observations and historical normalization remain unchanged. These
arithmetic improvements do not establish that inherited empirical calibration is
optimal for the improved statistics.

`--full-precision` optionally appends 17-significant-digit raw, p-value and signed
suspicion fields to each displayed row in either mode. Suspicion retains extreme
tail information when a binary64 p-value is zero or one. The default report format
is unchanged; the option does not change filtering or test arithmetic.

**Reason:** Preserve small deviations and finite tail information while keeping the
saved original useful for comparison. **Verification:** Independent Decimal and
closed-form scalar controls, exact binomial endpoints, retained reference-policy
checks, and the full six-case/4 GiB fixture comparison. The focused cross-machine
probe checks binary64 patterns; its scope and remaining limits are in the numerical
policy. No fixtures or comparison tolerances were changed.

## D005 — Platform scope

**Status:** Present in 0.1.0.

Upstream has additional Windows, word-size, and endianness portability code.
The current rewrite targets 64-bit little-endian macOS and Linux with a system
C runtime. Native execution was tested on ARM64 macOS. Other platforms remain
unvalidated and are not supported by this version.

**Reason:** Keep the initial supported environment explicit.
**Verification:** Native Debug and ReleaseFast build/run checks; additional
platform coverage remains in TODO.md.

## D006 — Measured resource use

**Status:** Intentional execution, allocation and input-batching differences.

Expanded reserves about 84.7 MiB of histogram address space and 128 MiB of
Birthday capacity per stream, plus NearSeq state and buffers. Extra folding runs
ten streams. A full-buffer Birthday sort can need another 128 MiB of workspace.
These are capacity reservations, not RSS estimates or long-run memory bounds.
Threaded CPU Expanded uses two 128 MiB input buffers and one additional host
thread for input/count overlap. Serial input uses 32 MiB. Threaded GPU input
uses one 128 MiB statistical buffer and the bounded reader slots described in
[GPU ownership and resources](gpu.md#ownership-and-scheduling).

Expanded transforms keep up to 4 MiB between normal flushes and reserve incoming
batch capacity. CPU counting uses up to four threads including the caller;
GPU pool sizing follows the backend and independent-family job count. Hardware
CPU availability bounds every pool. The core battery retains its existing buffer
sizes. CPU and GPU services own temporary memory through completion and teardown.

Input batches can affect statistics through inherited [UB014 Pat5 per-call tail
omissions](upstream-bugs/UB014-pat5-batch-tail.md). Original 0.96 defaults to serial
32 MiB calls; its threaded manager uses 128 MiB. With a 128 MiB stdin fixture,
Expanded raw folding and a planted Pat5 center at 96 MiB minus four bytes,
original default and rewrite `-singlethreaded` display `Pat5(*,g)` R=167.9;
original `-multithreaded` and rewrite default display R=169.3. The rewrite audit
uses `--reference-compatible`, which selects arithmetic and does not force
original serial batching. This inherited difference is statistical as well as
resource-related. Changing the default or Pat5 semantics remains a separate
compatibility decision; this organization changes neither.

**Reason:** Execution and resource requirements are user-visible.
**Verification:** Retained original fixtures, complete-state CPU/GPU tests and
matched-mode comparisons preserve the documented scope. Resource capacities
alone establish neither process RSS nor a general throughput advantage.

## D010 — FPF/64 checkpoint-independent sampling (bug fix)

**Status:** Intentional upstream bug fix, approved November 1, 2026.

Original PractRand 0.96 switches FPF/64's sampling alignment after its first
input call, so identical input can produce different results depending on the
first checkpoint. The rewrite uses the initial 64-bit alignment consistently:
FPF/64 results for a given input prefix no longer depend on the first checkpoint
or input batching. This applies to raw and folded Expanded streams. Its
statistics, available subtests, probabilities, evaluations, and resulting failure
stops may differ from upstream. FPF/32, FPF/16, and FPF/4 retain their existing
behavior.

**Reason:** Fix the confirmed upstream defect
[UB001](upstream-bugs/UB001-fpf64-checkpoints.md).
**Verification:** The retained isolated FPF kernel test checks histogram and
report equality across five first-checkpoint sizes and subsequent irregular
batches for all four FPF strides. The [reference fixture checks](testing.md)
exclude corrected FPF/64 values and available subtests, which can differ from
upstream. They do not add separate battery runs for checkpoint invariance.
The [independent FPF/64 controls](fpf64-verification.md) additionally compare
exact histograms with direct bit-window enumeration and reference scoring with
14 retained results from fresh original instances fed in one call. Those checks
do not change the existing fixture comparison or the nominal-count convention.

## D012 — Bad RNG results preserve tail endpoints

**Status:** Intentional correction.

For the bad-input cases consolidated in [UB004](upstream-bugs/UB004-bad-rng-nan.md),
the implemented NS3 normal-score conversion preserves signed infinite suspicion
and DC7's chi-square upper tail returns zero at positive infinity. The reproduced
positive extremes therefore report p=0 and FAIL instead of aborting on NaN.
NS3 negative infinite raw scores report p=1; both endpoints are failures.
DC7 uses a chi-square upper tail: its zero statistic gives p=1 and positive
infinity gives p=0. Negative chi-square statistics are outside its domain.
Raw statistics remain available; 0/1 are probability endpoints, not replacements
for the raw score.
Normal statistical-failure stopping options still apply.

Finite normal scores whose scaled square overflows also return signed infinite
suspicion, preserving the 0/1 endpoints. Other finite-input arithmetic is unchanged.
NaN inputs remain invalid; this is not a
blanket NaN-to-zero replacement. Gap-16 rounding is handled separately in D008.
Insufficient-data states,
experimental tests and NearSeq3 threshold exhaustion are not fixed by this change.
The upstream SFC8 NaN remains a known divergence beyond the current 256 MiB
reference-comparison limit. Later rewrite checkpoints have no reference report
comparison; see [testing scope](testing.md).

## D008 — Gap-16:C non-finite reference result

**Status:** Intentional numerical correction; diagnosis is maintained in
[UB006](upstream-bugs/UB006-gap16-rarity-nan.md).

A historical `stdin8 -tf 1` capture with checkpoints every 1 MiB made the
untouched x86-64 PractRand 0.96 reference abort at 22 MiB with
`error: garbage p-value in test results`, `test=[Low1/8]Gap-16:C`,
`pvalue=nan`, exit 1. The native ARM64 rewrite continued through that checkpoint.
The current diagnosis is in UB006 above. Equivalence for that historical input
is not claimed; its original fixture and captures are no longer retained.

**Reason:** Prevent the confirmed ordered-rarity cumulative-rounding defect.
The rewrite applies the existing score cap of 35 before evaluating logarithms
when a cumulative midpoint rounds to or beyond 0 or 1. Interior calculations
retain their existing expression. The lost historical fixture is not revalidated.
**Verification:** Historically reproduced against both implementations. That
fixture is outside the retained reference inputs.

## D024 — Safe entropy-pooling history insertion (bug fix)

**Status:** Intentional upstream bug fix, approved November 21, 2026.

Original PractRand 0.96's `EntropyPool_MetaRNG::evolve_seed()` decrements
`unordered_history.begin()` whenever a newly generated 64-bit hash is less than
or equal to the current minimum hash in the `std::multiset<Uint64>`. That
undefined behavior reads out of bounds into `history` under `libc++` and causes
intermittent `SIGSEGV` crashes in both `-ttep` and direct
`EntropyPoolingTester(...)` expressions; see
[UB007](upstream-bugs/UB007-entropy-pool-crash.md).

The rewrite replaces that hint insertion locally in `src/builtin_rngs.cpp`
(leaving `.vendor/PractRand/` byte-for-byte unchanged) by passing `sitr.first`
(`lower_bound(hash)`) directly to C++11 `unordered_history.insert(sitr.first, hash)`.
This applies to both `-ttep` and `EntropyPoolingTester(...)` in both default and
`--reference-compatible` modes. Valid output bytes are unchanged relative to
non-crashing upstream runs. [UB003](upstream-bugs/UB003-entropy-wrapper-bounds.md)
(parsing both wrapper bounds from `params[1]`) and `sha2_based_pool`'s original
basic check 3 rejection remain unchanged.

**Reason:** Eliminate confirmed undefined behavior and `SIGSEGV` crashes in
entropy-pooling runs while preserving the original output sequence and keeping
vendored sources untouched.
**Verification:** All three retained original 1,027-byte vectors in
`test/entropy-vectors.json` match across whole and irregular reads; `test/entropy_cli.py`
verifies `-ttep` at `1K` strings (`8 KiB`), `arbee` through 32,768 strings
(`262,144` bytes, over twice `history_length = 16,384`), and direct
`EntropyPoolingTester(...)` expressions for both `arbee` and `sha2_based_pool`;
ASan and UBSan pass cleanly on the adapter probe, and the full
`zig build test -Doptimize=ReleaseFast` suite passes.

## D025 — Defined binarymult16 product (bug fix)

**Status:** Intentional local arithmetic remedy; both result modes.

Original `binarymult16` multiplies promoted 16-bit operands as signed `int`,
which can overflow and abort Debug execution ([UB053](upstream-bugs/UB053-binarymult16-signed-overflow.md)).
The adapter retains the original state, seeding/walk order, recurrence and name,
using an exact unsigned 32-bit product before reducing to 16 bits. Vendor code
and original fixtures remain unchanged. Previously defined products are
identical; overflowing original expressions have no portable C++ result.

**Reason:** Define the generator's low 16-bit product without changing its
observed original vectors. **Verification:** An independent arbitrary-precision
oracle, untouched optimized original and sanitizer-instrumented adapter agree
on 98,304 words across seeded/boundary states. Existing retained original byte
vectors remain authoritative. The separate fibmulmix16 remedy is recorded below.

## D026 — Defined fibmulmix16 products (bug fix)

**Status:** Intentional local arithmetic remedy, approved November 22, 2026;
both result modes.

Original `fibmulmix16` multiplies promoted 16-bit operands as signed `int` in
both buffered refill loops. Overflow can abort Debug execution
([UB055](upstream-bugs/UB055-fibmulmix16-signed-overflow.md)). The local adapter
computes the product exactly as unsigned 32-bit arithmetic before reducing it
to 16 bits. Buffer order, position, state walk, seeding, name and recurrence are
preserved; neither vendored sources nor retained expected bytes are changed.
Previously defined products are identical; overflowing original expressions
have no portable C++ result.

**Reason:** Apply the same shared correctness policy as D025, allowing the
generator to continue with defined arithmetic in either result mode. Improved
statistical arithmetic remains a separate policy.
**Verification:** Retained original byte vectors cover whole and irregular reads
across refills. Independent arbitrary-precision recurrence and original-source
comparisons additionally exercise seeded/boundary states and buffered positions.

## D028 — Defined remaining built-in generator arithmetic

**Status:** Intentional local remedies, approved November 22, 2026; both result modes.

The broader native Debug audit reproduces promoted signed-product overflows in
`garthy16`, `mrc16`, `mrsf16`, `mulcrax16`, `mulcrx16`, `multish4x16`, the six
`mwlac_varA`–`mwlac_varF` variants, `mwrca16`, `mwrcc16`, `mwrcca16`,
`old_mwlac16` and `vf16`. Local adapters compute their 16-bit products using
exact unsigned 32-bit intermediates before the original reduction. The mrc16
seed mapping and nine warmup draws, candidate factories, flags, names, state
walks, counters and stream consumption are preserved.

`gjishC` and `varrotC` can rotate by zero through a helper that shifts by the full
32-bit width. `sfc_alt8`/`sfc_alternative8` use rotation 11 on an 8-bit word. The
local adapters define those rotations modulo the word width, including identity
at zero. Their retained original streams are preserved. The old undefined C++
expressions have no universal portable result.

The full-width Ranrot rotation defect has a separate remedy and explicit
compatibility choice under [D029](#d029--explicit-legacy-and-fixed-ranrot-generators).
Its original fixtures remain unchanged.

**Reason:** Extend the shared safety policy of D025/D026 to confirmed runtime
defects while preserving observed generator sequences.
**Verification:** A bounded native CLI audit covers all 732 retained seeded
cases. Forty-four affected fixture cases outside Ranrot match fresh optimized
original output and the actual local adapters with fatal UndefinedBehaviorSanitizer
checks, using whole/irregular fills and matching metadata. Vendor sources,
original fixtures and comparison rules remain unchanged. Individual evidence
and handling records are indexed in [upstream bugs](upstream-bugs/README.md).

## D029 — Explicit legacy and fixed Ranrot generators

**Status:** Intentional, approved November 22, 2026; both result modes.

Original `ranrot_var32` and `ranrot_var64` evaluate undefined full-width shifts
for zero rotations ([UB070](upstream-bugs/UB070-ranrot-zero-rotation.md)). The
frozen optimized original repeats its initial 45-word buffer instead of updating
it. Debug detects the invalid shift and aborts.

The original names now explicitly reproduce that captured repeating stream with
defined arithmetic, preserving seeding, state walk, counters and reverse output
order. Selecting either name prints a warning recommending its `_fixed` option,
also when nested inside another expression. Each affected width is reported
once per constructed expression; other initialization warnings are retained.
This defines the observed frozen behavior, not every possible compiler outcome
of the original undefined code.

`ranrot_var32_fixed` and `ranrot_var64_fixed` instead implement the intended
changing recurrence, treating the two zero rotations as identity. Their reported
names are `ranrot_variant32_fixed` and `ranrot_variant64_fixed`. They retain the
original seed mapping, state walk, counter timing and reverse read order.
Choosing `--reference-compatible` changes statistical arithmetic, not which
Ranrot stream these explicit names select.

**Reason:** Preserve reproducible original streams while making their defect
visible and offering the intended generator without silently replacing them.
**Verification:** All original byte fixtures remain authoritative. Separate
retained controls cover both fixed widths and both original fixture seeds over
65,539 bytes, using whole/irregular reads. Their expectations come from an
independent Python integer model and seed states captured by an untouched
original driver that never calls the undefined refill. CLI checks cover both
result policies, nested/repeated selections and combined warning diagnostics.

## D018 — C8 uses every Arbee output bit

**Status:** Intentional, November 7, 2026.

Original 0.96 generates one 64-bit Arbee word per two `[C8]` classifications,
uses its low 16 bits, and discards the rest. The rewrite consumes all 64 bits,
lowest first, across eight classifications. Every 16-byte input block reserves
eight bits, even when none of its counts needs tie-breaking. Arbee advancement
depends only on the amount of classified input, independently of input values
and tie counts.

Unconsumed bits carry over between calls and CPU/GPU handoffs. Batching and
execution choice do not change the tie-bit sequence. The fixed OddPhi seed in
[D017](#d017--fixed-c8-seed) remains. Classification bytes, downstream `[C8]`
statistics, and failure stops can differ from upstream and earlier rewrite
versions, even when the initial seed matches. Other streams' calculations
retain their existing behavior.

**Reason:** Use every generated bit while keeping RNG work independent of ties.
**Verification:** Direct bit-counting and byte-stream oracles cover complete and
partial words, unaligned input, tie-heavy and tie-free input, and irregular
scalar/vector calls. Hardware checks compare CPU/GPU bytes and complete state
through partial-word handoffs. The diagnostic original used for the durable
reference fixtures also consumes complete words, allowing the full test target
to compare `[C8]` values as well as names.

## D017 — Fixed C8 seed

**Status:** Intentional, November 7, 2026.

Original 0.96 seeds each `[C8]` transform's internal Arbee from the tester's
auxiliary RNG, so classifications can differ between runs of identical input.
The rewrite always seeds every `[C8]` stream, including folded streams, with
OddPhi `0x9e3779b97f4a7c15` as the low word and zero as the high word. CPU and GPU
use the same initialization and the usual eight seed-warmup steps. Subsequent
tie-bit consumption is described in [D018](#d018--c8-uses-every-arbee-output-bit).

Together with D018, this makes classification deterministic for the same input
regardless of call batching. Stdin's `-seed` remains a report label and cannot
override this seed.
Expanded startup no longer acquires OS entropy or fails because it is unavailable.
`[C8]` values can differ from upstream and from earlier randomly seeded rewrite
runs. The diagnostic original used for the durable reference fixtures matches
this initialization, so the full test target compares `[C8]` values too.

**Reason:** Make classification repeatable with the requested fixed seed.
**Verification:** Existing serial/parallel state and result checks use the fixed
initialization. Repeated Expanded CLI runs with extra folding compare complete
statistical reports, including `[C8]` values, after excluding timing and seed labels.

## D003 — Floating-point equivalence has a tolerance

**Status:** Observed in 0.1.0; no intentional statistical change.

The same input can produce slightly different full-precision results on the
reference x86-64 build and the native ARM64 rewrite. In 429 checked rows through
32 MiB, maximum absolute differences were approximately `4.1e-8` in raw statistics
and `4.3e-8` in suspicion. Displayed reports matched in the checked cases.
Expanded comparisons through 128 MiB are recorded in
Expanded validation, including matching non-finite
results and larger absolute errors on large counter-input tails.
Values extremely close to display, selection, or failure boundaries could expose
a difference; bit-for-bit numerical equality is not promised.

**Reason:** The first version targets the calibrated upstream behavior with a
measured numerical tolerance. **Verification:** Full-precision comparison and
its tolerances are documented in validation.

## D004 — Invalid and unsupported requests fail with status 1

**Status:** Intentional in 0.1.0.

Upstream often prints an error and exits 0 for invalid options or values, although
some errors exit 1. This version reports invalid or unsupported requests on stderr
and exits 1. Error wording also differs: missing values identify the option, and
invalid length/report-threshold diagnostics identify both the option and value.
Invalid requests are diagnosed before consuming stdin. A real stdin read error
exits 1. Expanded setup needs no OS entropy under [D017](#d017--fixed-c8-seed).

Duration conversion must also produce finite seconds. The rewrite rejects a
finite decimal duration whose unit multiplication overflows, rather than
accepting an unreachable infinite deadline as upstream does; see
[UB020](upstream-bugs/UB020-duration-overflow.md).
Valid lengths use the original digit-by-digit decimal calculation before unit
scaling and complete-block truncation, including the rounding behavior in
[UB051](upstream-bugs/UB051-decimal-length-rounding.md), in both result modes.

Invalid result probabilities and weights now abort with status 1, identifying
the test in the report, matching upstream's sanity checks. Known infinite NS3/DC7
statistics instead report failing probabilities as described in D012. NearSeq3
threshold exhaustion remains an error. Error wording on stderr differs. This does not close
the separate Gap numerical difference recorded in D008.

Calibration now preserves a NaN sample for that fatal result validation instead
of silently converting it to a median score. Upstream also rejects NaN samples,
but reports its calibration error directly. The isolated rewrite check covers
all imported calibration rows with and without tail extrapolation; no new
byte-stream trigger is claimed.

An exhausted stdin retains upstream behavior: `error reading from file` on stderr,
exit 0, and no zero-padding or fabricated partial checkpoint. Threaded CPU
Expanded joins its pending update first, so a counting failure takes precedence
over exhaustion. Its next bounded read can delay observation of that failure
until the read fills or ends; D007 records the associated read-ahead.

**Reason:** Scripts should be able to detect an unsupported or invalid request.
**Verification:** Missing values, unsupported inputs/batteries/options,
invalid lengths, non-finite thresholds, and short/empty input were exercised.
Overflowing minute/hour/day durations were checked without initializing a
battery. The developer benchmark likewise rejects non-finite `--seconds` values
before starting a generator or tester.

## D016 — Stdout failures are errors

**Status:** Intentional correction.

Original 0.96 does not check its report writes or final stdout flush, so lost
output can still accompany successful completion or a normal statistical-failure
stop. The rewrite checks both the flush result and stdout's sticky error flag at
completed checkpoints and after successful CLI completion, including help and
version output. A detected output failure exits 1 with `OutputFailed` on stderr.
Earlier run errors, including invalid weights/probabilities, retain precedence.

**Reason:** Prevent successful status from hiding failed output; see
[UB030](upstream-bugs/UB030-unchecked-output-errors.md).
**Verification:** Isolated synthetic-result probes cover writable/read-only stdout,
buffered/unbuffered output, unchanged statistical decisions and numerical-error
precedence. Help/version probes cover successful paths without checkpoints.
The normal full suite validates writable report output and upstream parity.

## D013 — Reports sorted by test name

**Status:** Intentional, requested November 1, 2026.

Upstream prints checkpoint results in battery and transform traversal order.
The rewrite prints selected rows in ascending, case-sensitive byte order of
the full displayed test name, including transform prefixes and subtest suffixes.
This applies to full and filtered reports in both serial and parallel execution.
Names are unique within a checkpoint; stable sorting is not required.

**Reason:** Make each checkpoint's results easier to locate by name.
Validation, weight summation, result values, filtering and failure decisions
retain their existing behavior; only presentation order changes.
**Verification:** Synthetic checkpoint rows exercise sorting and filtering without
running a battery. The fixture comparator matches rows by name within each
checkpoint and rejects duplicate names; values, row multiplicity and checkpoint
boundaries remain checked. See [testing](testing.md).

## D015 — Monotonic elapsed time

**Status:** Intentional correction.

Original 0.96 calculates elapsed time from adjustable calendar clocks. The
rewrite uses the OS monotonic clock for reported elapsed time and duration-based
checkpoints and stopping. Wall-clock corrections therefore cannot advance or
postpone those events. Byte-based scheduling and statistical calculations retain
their existing behavior. An unavailable monotonic clock is an error on stderr
with exit status 1.

**Reason:** Fix the clock-selection defect documented in
[UB029](upstream-bugs/UB029-adjustable-elapsed-clock.md).
**Verification:** Synthetic clock values exercise duration stopping and clock-read
failure without changing the machine clock or using workload timings as evidence.
Native builds and the full reference-comparison suite check integration; elapsed
time remains excluded from statistical report comparison.

## D007 — Bytes consumed from stdin at an early stop

**Status:** Present in 0.1.0.

With `stdin8 -tf 0 -tlmin 1K -tlmax 1K -a`, the original consumes 4 KiB from
stdin before exiting; the rewrite consumes 1 KiB. Both report the same 1 KiB
prefix. A caller that shares and later reuses the input file descriptor can
therefore resume at a different file position. Other stopping points can also
differ in the amount of input consumed beyond the tested prefix.

**Reason:** Early-stop input consumption has not yet been matched to upstream.
**Verification:** A parent process supplied the same open file to each executable
and checked the shared file offset after completion.

Threaded CPU Expanded now reads ahead by at most one 128 MiB logical buffer
within the existing 256 MiB outer step while its previous buffer is counted.
Every step is drained before checking time or reporting. It does not read beyond
a completed checkpoint to prepare the next step, but a counting failure can
occur after the next buffer has already been consumed. Exhausted input waits
for a pending update before returning, without padding or reporting a partial
buffer. GPU input uses the bounded reader described in D014. The
CPU scheduling study records the frozen replay
and state checks; the original-versus-rewrite file-position gap above remains.

## D014 — Optional GPU execution

**Status:** Intentional optional execution/resource difference.

`-gpu`/`--gpu` requests eligible exact integer Expanded Mod3/DC7 and FPF/4 work
alongside the CPU pool. The current Vulkan backend also counts FPF/16 in the
same pass; older libraries retain the CPU FPF/16 path. Both current backends keep
C8 on the CPU pool, while older Vulkan libraries without FPF support use GPU C8.
Native Metal is preferred on macOS and builds with `-Dmetal=true` without a
Vulkan SDK. Vulkan is an explicit `-Dvulkan=true` option. The former
`-Dmetal-fpf=true` and library path remain compatibility aliases.

Original PractRand has no corresponding GPU option. CPU execution remains the
default. Core GPU requests and unavailable or failed GPU execution exit 1;
failures are not silently ignored. Unsupported counter capabilities and small
calls use the documented CPU paths. The banner identifies the selected backend
and device. The [GPU guide](gpu.md) defines capacities, host threads, integer
requirements, fallback entry points and failure handling.

Threaded GPU input may read or generate ahead in bounded owned slots; input
limits bound prefetch. Early stopping can leave prefetched input uncounted, and
teardown joins the producer before destroying a borrowed generator. Exact
histograms, logical counting/flush/checkpoint boundaries, random tie progression
and numerical evaluation remain shared with CPU execution. Native hardware tests
and the reference comparison contract describe the tested correctness scope;
these tests do not certify performance on other hardware.

## D002 — Program identification and help

**Status:** Intentional in 0.1.0.

Upstream identifies itself as PractRand 0.96 and derives displayed program names
from the executable basename. This version identifies itself as practrand-zig
0.2.0, names reference version 0.96, uses `RNG_test` in help and banners,
and documents its supported subset. `--version` and help text therefore differ.

**Reason:** Users must be able to identify which executable produced a report and
which commands it supports. **Verification:** Help/version probes pass; report
comparisons exclude only the identifying banner and timing, while checking the
remaining report contents and checkpoint lengths.

## D009 — Research SFC8 stream generator

**Status:** Intentional standalone test utility.

Original PractRand 0.96 supplies SFC16/32/64, without an SFC8 generator.
[Our standalone utility](../tools/sfc8.c) uses the same recurrence with eight-bit
words and fixed `(right,left,rotate-left) = (1,3,4)`. Its only invocation is
`sfc8 SEED BYTE_COUNT`. It seeds all four words equally and discards nine outputs.

**Reason:** Provide a reproducible SFC8 input for the historical two-source parity check.
**Verification:** Its output is unchanged for the chosen constants. The utility
does not add a built-in RNG to the statistical tester.

Its numeric parser rejects negative arguments even after leading whitespace,
and rejects whitespace-only arguments. Positive inputs retain their existing
base-prefix and leading-whitespace support. Before this validation fix,
`strtoull` could wrap a whitespace-prefixed negative value into a valid seed or
an unexpectedly large byte count. Parser probes reject those cases, and valid
seed 0/1/255 streams match the prior utility byte for byte across a buffer boundary.

## D011 — License for original rewrite contributions

**Status:** Intentional; MIT selected November 1, 2026.

Original PractRand dedicates its statistical tests and auxiliary code to the
public domain under CC0 1.0. This project's original contributions use the
[MIT License](../LICENSE), which requires preservation of its copyright and
license notice in distributed copies or substantial portions. Upstream material
retains its existing terms and notices; see [licensing scope](../README.md#credits-and-licensing).

**Reason:** Give the rewrite explicit permissive licensing while preserving
upstream rights and attribution. **Verification:** Checked the upstream CC0
terms, retained the original license and imported-data notices, and verified the
licensing links. No executable behavior changed.
