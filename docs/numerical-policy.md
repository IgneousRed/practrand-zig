# Numerical precision and platform policy

Improved mode is the default. `--reference-compatible` preserves comparability
with the saved original results under the [reference contract](testing.md#reference-compatible-results).
The imported calibration observations, historical chi-square normalization,
empirical permutation split ratios, and existing accepted corrections are unchanged.

## Improved calculations

1. **Centered G-test:** binary64 arithmetic, split integer conversions, explicit
   fused product/division residuals, small- and moderate-deviation series and compensated
   accumulation preserve small count differences. The represented model's total
   probability residual remains part of the statistic. See
   [UB024](upstream-bugs/UB024-g-test-cancellation.md).
2. **Retained tails:** BRank's small-sample exponential approximation is stored
   with its direct signed suspicion. DC7 combines component log probabilities
   and retains the signed logarithmic survival result through reporting. A centered
   series, expm1 and an extreme-small-input logarithmic form preserve both tails.
   When both DC7 component suspicions exceed 512, their complementary probabilities
   are combined in scaled logarithmic form through the final suspicion. This
   retains a finite result even when the combined chi-square statistic underflows.
   A probability can still round to zero or one; its finite suspicion need not.
   See [UB034](upstream-bugs/UB034-brank-tail-roundtrip.md) and
   [UB004](upstream-bugs/UB004-bad-rng-nan.md#november-13-retained-dc7-log-tails).
3. **Near-neutral transforms:** p-value-to-suspicion uses log1p near one half;
   normal suspicion uses a linear limit for tiny inputs and log1p with a rational
   erf approximation near zero. Far-tail handling
   remains separate so rounding a relative difference to -1 cannot destroy it.
   See [UB032](upstream-bugs/UB032-pvalue-center-cancellation.md) and
   [UB033](upstream-bugs/UB033-normal-score-center-cancellation.md).
4. **Birthday:** the large-count log-tail expression is centered and evaluated
   by series near its maximum. Low integer bits survive conversion above 2^53.
   The same integer residual now drives the raw score, tail selection and sign;
   these no longer first round the observed count to binary64.
   The zero-count expression simplifies algebraically; the normal-approximation
   branch produces suspicion directly. For lambda <= 64, the midpoint Poisson
   probability is evaluated from the smaller tail with compensated recurrence
   and summation. The upper recurrence stops when a geometric remainder bound is
   below one quarter of a binary64 relative ulp. Historical approximations, branch thresholds
   and calibration remain. See [UB036](upstream-bugs/UB036-birthday-tail-cancellation.md).
5. **Probability models and rarity:** permutation categories are counted as exact
   integers and divided once. Hamming uses binary64 recurrence, compensated CDF
   sums and Zig's frexp/ldexp without the arbitrary subnormal cutoff. Ordered and
   unordered rarity form the numerator from `count - N*p`, with split integer
   totals and fused product residuals, instead of multiplying rounded centered
   weights by large counts. Ordered rarity retains its distinct forward mean and
   reverse upper-tail weights, including their correction for non-unit models.
   That correction uses a centered log1p ratio when subtracting nearby weights
   would lose the model-mass residual, including the quadratic term at the center.
   Mean, variance and signed actual-score sums are compensated;
   ordered cumulative sums are compensated and complementary logarithms use log1p.
   Rarity remains finite precision; compensation does not make every logarithm,
   product or rounded model exact. See [UB035](upstream-bugs/UB035-permutation-probability-accumulation.md)
   and [UB037](upstream-bugs/UB037-hamming-subnormal-cutoff.md).
6. **FPF overall:** the nominal-count G-test is centered separately from its
   signed linear residual. Nominal expectations need not sum to observed counts;
   neither renormalizing them nor clamping negative results is equivalent. See
   [UB038](upstream-bugs/UB038-fpf-overall-cancellation.md).
7. **Gap probabilities:** `exp(first*logq) * -expm1(width*logq)`, with
   `logq=log1p(-1/65536)`, avoids subtracting nearby powers. Startup normalization
   sums retained mass with compensated products, then adds the represented model
   residual `1-sum(p)`. This preserves `1-sum(p*fraction)` without cancelling
   nearly unit discarded mass. Startup fractions, bin boundaries and merging
   remain unchanged. Cached and fallback models both
   use the selected arithmetic policy. See
   [UB039](upstream-bugs/UB039-gap-bin-cancellation.md).
8. **Accumulation:** NearSeq3 model moments, signed sample and pair scores, and
   decayed history totals use compensated binary64 sums. Scaling carries the
   multiplication residual into the low component. BRank retains a low component
   alongside its original running total; reference results use only the original
   total. Sampling, thresholds and score definitions are unchanged. See
   [UB042](upstream-bugs/UB042-score-accumulation.md).
9. **Calibration interpolation:** the integer interval and local fraction remain
   separate until a fused multiply-add produces the probability. This avoids
   discarding fraction bits in an integer-plus-fraction round trip. Calibration
   rows, interval search, tail slopes and the historical sample adjustment remain
   unchanged. See [UB043](upstream-bugs/UB043-calibration-index-roundtrip.md).
10. **Hamming log scores:** NearSeq3 models retain a scaled log-CDF alongside the
    ordinary CDF. Scores remain finite when the probability itself underflows;
    subnormal CDFs also avoid loss of relative accuracy before taking logarithms.
    Ordinary CDF values and threshold decisions are unchanged. These are derived
    model arrays, not saved-state changes. See
    [UB044](upstream-bugs/UB044-hamming-log-tail-underflow.md).
11. **Report filtering:** improved mode compares direct tails or retained
    suspicion instead of subtracting both probability and threshold from one
    half. Reference mode retains the previous comparison. CLI threshold limits,
    result validation, evaluation labels and the all-results option remain
    unchanged. See [UB045](upstream-bugs/UB045-report-tail-filter-cancellation.md).
12. **Normal log tails:** the moderate-range alternating erf series and continued
    fraction are replaced in improved mode by a pure-Zig, piecewise rational
    kernel, evaluated directly in log form in the tails. A bounded asymptotic
    expansion extends beyond the ordinary erfc underflow range. The original
    normal variate supplies the dominant squared term through an explicit FMA.
    Reference mode retains its existing kernel. See
    [UB023](upstream-bugs/UB023-normal-cdf-erf-cancellation.md#november-13-moderate-normal-tail-precision).

13. **BCFN marginals:** each effective bit width uses its direct Bernoulli model,
    with log1p around the existing balance constant and exact binary scaling by
    2^-bits. This avoids folding up to 512 rounded probabilities per bin and
    subtracting a rounded bits*ln(2) inside exp. Balance constants, integer count
    folding, sample thresholds and calibration are unchanged. See
    [UB048](upstream-bugs/UB048-bcfn-probability-folding.md).
14. **NearSeq conditional probabilities:** ordinary PDFs are divided directly by
    the conditioning CDF. When the CDF is subnormal or zero, a compensated
    downward binomial recurrence uses unit weight at the threshold and normalizes
    the relative weights. No reciprocal overflow or absolute tail probability is
    needed. Existing CDF-based threshold selection, filtering ranges, the upstream
    integer filter-rate convention and threshold exhaustion are preserved. This
    does not repair every degenerate/invalid NearSeq state. See
    [UB049](upstream-bugs/UB049-nearseq-conditional-underflow.md).

The count-residual evidence for Birthday and rarity is recorded separately in
[UB040](upstream-bugs/UB040-birthday-integer-residual.md) and
[UB041](upstream-bugs/UB041-rarity-count-cancellation.md).
The small-Poisson-tail evidence is in
[UB046](upstream-bugs/UB046-birthday-midpoint-tail-cancellation.md).

Gap's startup-normalization evidence is recorded in
[UB047](upstream-bugs/UB047-gap-startup-normalization.md).

Each affected helper/table is selected by the immutable run policy. Reference mode
keeps the previous expressions and summation order, including the historical
Hamming cutoff and repeated permutation increments. Its G-test and Hamming
intermediates remain f80 on x86-64 and f64 elsewhere. Improving default arithmetic
does not change the original fixture data or relax the comparison rules.

## Types and reproducibility

Stored statistics and improved floating intermediates are IEEE binary64 (`f64`).
Histogram counts remain integer. Compensated accumulators store two f64 values;
they are not f80, f128, or an arbitrary-precision number type. The reference-only
wider intermediates are intentional compatibility behavior.

Builds and tests use the locked Zig compiler through `scripts/dev`, without
a host-compiler fallback. Lock updates require explicit review. Compiler and
standard-library math changes are validated by
the full numerical/reference suite using that compiler; the retained reference
fixtures and comparison rules remain unchanged.
Zig's strict floating-point mode remains in effect; critical compensation,
centered arithmetic and Hamming routines explicitly select it. There is no
fast-math reassociation policy. Explicit `@mulAdd` is retained where one rounding
is necessary to recover multiplication/division residuals. Operation order and
serial/parallel checkpoint collection remain deterministic within the run policy.

This removes known architecture-dependent precision choices from improved mode
and removes its system erfc and Hamming frexp/ldexp paths. It is **not** a universal
bit-identity guarantee: remaining log/exp/pow operations can depend on target math
lowering or the C runtime. The operating system's math library can change
independently of Zig. Round-to-nearest and normal subnormal handling are assumed; no
foreign embedding that changes the floating-point environment has been validated.
A fully specified software transcendental library would require separate selection
and accuracy validation. No new numerical dependency was added.

## Normal-tail kernel provenance

The rational coefficients in [normal_tail.zig](../src/normal_tail.zig) come from
[musl's fdlibm-derived erf.c](https://git.musl-libc.org/cgit/musl/tree/src/math/erf.c),
read from `lib/zig/libc/musl/src/math/erf.c` in the Zig 0.17.0 installation used
for the original audit.
That source file has SHA-256
`795f05c9388ac277ab27cb5dc63fb4f82620a0ee11eaf8403201df5bc65c0f5b`.
The [permission notice](../LICENSES/fdlibm.txt) is retained in the kernel too.
No system erf/erfc call or additional library is used by the improved kernel.

The adaptation uses explicit FMA Horner evaluation, log1p near zero, and a direct
logarithmic tail. Beyond x=28, the positive-real asymptotic expansion and its
first-omitted-term bound follow [DLMF 7.12.1](https://dlmf.nist.gov/7.12.i).
Independent controls cover all branch boundaries, the former cancellation case,
subnormal inputs and extreme tails. This validates the tested accuracy; it is
not a claim of correctly rounded results for every binary64 input.

## Full-precision reporting

Add `--full-precision` to append `raw=`, `p=`, and `suspicion=` values using 17
significant decimal digits, enough to round-trip finite binary64 values. It works
in either arithmetic mode and with `-a`, `-p`, and `-e`, regardless of option order.
It changes neither row selection nor the calculation. Default reports retain
the familiar original precision and layout.

```sh
.work/install/bin/RNG_test sfc64 -seed 0 -tlmin 1M -tlmax 1M -a --full-precision
.work/install/bin/RNG_test sfc64 -seed 0 -tlmin 1M -tlmax 1M -a --reference-compatible --full-precision
```

Use suspicion to retain tail information when p is zero or one. Seventeen digits
of output do not imply seventeen digits of statistical calibration accuracy.

## Independent controls and validation

The tests in `src/statistics.zig` include 110-digit Python Decimal controls for
G-test, DC7 tails, Birthday and rarity. Decimal controls use exact integers and
exact represented binary64 model probabilities where applicable. The formulas are:

1. G-test: `2*sum(n*ln(n/(N*p)))`, including non-unit model totals.
2. DC7: `ln(p)=ln(1+chis/2)-chis/2`, then the signed base-two tail.
3. Birthday: `n*ln(lambda/n)+n-lambda`, evaluated before rounding to binary64.
4. Rarity: direct high-precision weighted mean, variance and signed centered sum,
   using the same probability model and score definition.
5. FPF overall: `2*sum(n*ln(n/E))` with fixed nominal expectations, including
   signed nonzero total residuals and counts above 2^53.
6. Gap bins: exact rational `q=65535/65536`, evaluated as
   `q^first*(1-q^width)` at 110-digit precision.

Rarity controls include exact-proportion histograms, a one-count perturbation
above 2^53, and a deliberately non-unit scalar model. The latter uses decimal
probabilities 0.125, 0.375 and 0.4 with a tolerance that includes binary64 input
rounding; it tests formula preservation, not an accepted upstream input stream.
Additional exact-binary64 controls cover model totals 1 plus or minus 2^-45,
where subtracting forward and reverse weights directly would lose precision.
NearSeq3's small model is checked against exact binomial probabilities and
high-precision mirrored-CDF moments. Exact arithmetic identities check compensated
product/scaling residuals and interpolation at rounding boundaries. A synthetic
Birthday scoring state checks raw score and suspicion consistency above 2^53;
that state is not claimed to be stream-reachable.

Near-zero normal suspicion is checked against its analytic derivative at zero.
Hamming endpoint controls use exact binomial coefficients and bit patterns,
including 2^-1074. Log-CDF controls additionally cover exact zero/one-weight
formulas at 8192 bits and subnormal CDFs at 1075 bits. A synthetic NearSeq3 state
checks finite sample/pair scores without changing their counts. Forty-one
450-digit Decimal controls cover the new normal kernel, with adjacent branch
inputs and a separate 16,384-point monotonicity grid. Fifteen Decimal midpoint
Poisson controls cover both tails and the mean. Reporting tests distinguish
retained tails at rounded probability endpoints and supported threshold neighbors;
the more extreme scalar thresholds in those tests do not expand CLI limits.
A BRank result test checks finite improved suspicion against
the retained reference infinity. Permutation checks verify model mass without
rewriting empirical observations. These checks supplement full stream comparisons;
they do not establish new original full-stream failures or recalibrate the tests.

On November 13, 2026, the DC7-combination follow-up passed 64 Zig tests, 37 Python
checks, and the full ReleaseFast comparison of all six fresh SFC16/32/64
cases (both modes, 23 checkpoints each through 4 GiB), matching saved original
reports under the existing FPF/64 exception. Fixture contents, integrity checks
and comparison tolerances were unchanged. Twenty scalar tests passed on native ARM64
macOS and x86-64 macOS under Rosetta. The following focused probe produced identical
bit patterns for its twenty-four cases on those two targets:

```sh
python3 -B tools/zig_run.py build numerical-probe -Doptimize=ReleaseFast
python3 -B tools/zig_run.py build numerical-probe -Doptimize=ReleaseFast -Dtarget=x86_64-macos
```

The native Debug build and Linux x86-64 GNU cross-build also passed. Debug smoke
runs exercised both modes through 64 KiB with full-precision output. Earlier CLI
checks covered all three filters and either option order, preserving ordinary rows
when diagnostic fields were removed.

The probe prints names and binary64 hexadecimal representations, uses volatile
inputs for runtime transforms, and includes Hamming/subnormal and large-count
cases. Matching this small probe is evidence for those cases, not a proof over all
inputs, math functions, operating systems or compiler versions. Timing from these
runs is not performance evidence.

## Linux validation

A Linux cross-build proves compilation and linking only. Native Linux execution
remains unvalidated. On the intended Linux host, use the same Zig version and:

1. Run the [full suite](testing.md#full-test-suite), preserving the durable fixtures.
   Require all six cases, full input hashes, checkpoint sequences and displayed
   reference rows to pass. Investigate differences; do not widen tolerances merely
   because the host differs.
2. Run `numerical-probe` and compare its hexadecimal output with the macOS capture.
   A discrepancy identifies a calculation to investigate even if report rounding
   hides it. Run the scalar controls too; a matching fingerprint alone does not
   establish mathematical accuracy.
3. Exercise the CLI's full-precision output and serial/parallel operation on
   identical fixed inputs. Run the optional GPU suite only when that backend is
   part of the intended deployment.

Inherited empirical calibration was collected from original implementations.
Better arithmetic is not proof of better-calibrated p-values. Paired known-good
multiple-seed, multiple-length distribution checks remain necessary before claiming
that the improved mode has newly validated calibration, especially in extreme tails.

## Model-normalization follow-up controls

Additional independent 110-digit controls cover direct Bernoulli marginals,
Gap startup probabilities at 3, 128 and 1024 blocks, exact binomial conditional
probabilities, and G-test deviances on both sides of the series boundaries.
Gap controls use exact geometric probabilities and the existing represented
startup fractions; their tolerance includes base-table rounding. NearSeq has a
synthetic scoring-state check with a zero conditioning CDF and unchanged threshold
exhaustion. This is not a retained byte-stream reproduction. The numerical probe
also includes underflowed conditional probabilities and moderate G-test deviations.

## DC7 extreme combination controls

For component suspicions a,b > 512, set m=min(a,b). The combined signed suspicion
is evaluated as `2*m + 2*(1-log2(1+2^-abs(a-b)))`, using log1p and explicit FMA.
With q_i=1-p_i=2^(-s_i-1), this follows from x=-ln(p1*p2) and the lower tail
`1-exp(-x)*(1+x)`. In this range, replacing x by q1+q2 and that tail by x^2/2
has relative error below 2^-512, far below binary64 rounding. The scaled ratio
may underflow when one contribution is negligible; the dominant tail is retained.
The ordinary-range kernel and reference-mode expression remain separate.

Ten independent 1500-digit Decimal controls cover ordinary and extreme pairs,
the 512 boundary, unequal tails and opposite signs. Additional checks preserve
true infinities and NaNs. The pair (1200,1200) retains suspicion 2400 while its
chi-square statistic rounds to zero and its reported probability rounds to one.
This is scalar evidence, not a newly reproduced original byte-stream failure.
See [UB004](upstream-bugs/UB004-bad-rng-nan.md#november-13-extreme-dc7-component-combination).
