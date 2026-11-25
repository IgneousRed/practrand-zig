# UB004 — Bad RNG input produces NaN instead of a failing result

**Status:** Confirmed upstream bad-input handling bug, grouped by user-visible
behavior. Different numerical mechanisms are retained below. The rewrite fixes
the implemented NS3/DC7 infinite-statistic conversions; experimental classes
remain outside its implemented subset.

Extremely nonrandom streams should produce a failing result, not an invalid
probability. This record consolidates NS3, DC7, bad-input empty histograms,
GapUniversal3's guarded internal NaN, and the shared infinity conversions.
It excludes Gap-16 model rounding (UB006), insufficient input alone, and
unrelated helper defects. See [D012](../departures-from-upstream.md#d012--bad-rng-results-preserve-tail-endpoints).

## NearSeq3

The following captures predate the rewrite fix.

With zero input, both CLIs abort at the 2 KiB checkpoint with
`test=NS3[4:hw:both]`, `pvalue=nan`. The separate threshold-exhaustion path is tracked in [UB012f](UB012f-threshold-exhaustion.md).

The retained SFC8 source (chosen shifts/rotation `(1,3,4)`, seed zero, nine warmup
outputs) reproduces `test=NS3[4:pd:both]`, `pvalue=nan` at **512 MiB (2^29 bytes)**
with `stdin8 -te 1 -tf 2 -tlmin 1K -tlmax 4G -tlmaxonly -a -seed 0` (plus
`-skip_selftest` for upstream). Both executables exit 1 at that checkpoint.
Their reports match under the [parity comparison rules](../testing.md), including
the invalid-result diagnostic; rewrite stderr additionally names `InvalidPvalue`.
This prevents the requested 4 GiB SFC8 run from completing. Captures and command
metadata are retained locally.

The isolated audit reproduces the zero-input failure at 2 KiB with an infinite
raw `NS3[4:hw:both]` score passed into `math_normaldist_to_suspicion`. That helper
returns NaN at infinity ([UB004](UB004-bad-rng-nan.md#shared-normal-infinity-conversion)). A repeated byte ramp similarly reaches an
infinite raw `NS3[4:pd:both]` at 2 KiB. This explains those conversions; it does
not settle every source of extreme or non-finite scores inside NS3.

Repeated random data can produce NS3 NaNs at longer checkpoints as well.
Historical validation observed this behavior too.
The rewrite now maps an infinite normal score to signed infinite suspicion,
so positive infinite raw scores report p=0 and negative infinite raw scores
report p=1. Both endpoints report FAIL. NaN inputs remain NaN.
NearSeq3 threshold exhaustion is a separate error and is not fixed here.

### SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

Related historical NaN reports: see [search context](README.md#historical-nan-reports). No exact test/cause match found.

Search terms: `NearSeq3, NS3, hw:both, pd:both, NaN`. See [search scope](README.md#search-scope) for coverage and limits.

## DC7 independence

**Status:** Reproduced upstream numerical error; fixed for DC7 in the rewrite.

The isolated upstream driver reproduces `DC7-9x1Bytes-1:indep` with NaN at
4 KiB of zero or `0xff` bytes, and at 8 KiB of the repeated byte ramp. Its
independence calculation takes `log(0)` when a component p-value underflows,
then passes infinity to `math_chisquared_to_pvalue(..., 4)`. The gamma recurrence
forms infinity minus infinity; its final clamps do not catch NaN. The shared
conversion is also reproduced directly in [UB004](UB004-bad-rng-nan.md#shared-chi-square-infinity-conversion). A historical extreme-input
capture observed the same result at 256 KiB.
The reference CLI rejected the invalid probability and exited 1. This was not
an ordinary statistical `FAIL` result. That input fixture and its captures are
no longer retained; this entry preserves the observation and source analysis.

The rewrite returns the limiting upper-tail probability 0 for a positive
infinite chi-square statistic. Finite inputs retain the upstream evaluation
order; unrelated invalid results still fail validation.

### SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

Related historical NaN reports: see [search context](README.md#historical-nan-reports). No exact test/cause match found.

Search terms: `DC7, indep, log(0), infinite chi-square`. See [search scope](README.md#search-scope) for coverage and limits.

## Shared chi-square infinity conversion

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. Rewrite handling is described above for the implemented conversions.

`math_chisquared_to_pvalue(infinity, d)` returns NaN for tested integer degrees 3 through 8. Degrees 1 and 2 return 1. The regularized gamma recurrence forms infinity minus infinity; its final clamps cannot catch NaN. DC7 reaches the degree-4 case ([UB004](UB004-bad-rng-nan.md#dc7-independence)).

`math_lower_incomplete_gamma(2, infinity)` reproduces the same recurrence failure directly. No active test caller of that unregularized helper was found. Both are in original `src/math.cpp` and are exercised by the retained scalar probe.

### SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `math_chisquared_to_pvalue, math_lower_incomplete_gamma, infinity, gamma`. See [search scope](README.md#search-scope) for coverage and limits.

## Shared normal infinity conversion

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. Rewrite handling is described above for the implemented conversions.

`math_normaldist_to_suspicion(infinity)` returns NaN because its private `math_erfcx` evaluates infinity/infinity. Infinite NearSeq3 raw scores reach this path ([UB004](UB004-bad-rng-nan.md)). Finite magnitudes through `DBL_MAX` produced finite values or infinity, not NaN. Source: original `src/math.cpp`; retained scalar probe and NS3 byte-stream reproductions.

### SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `math_normaldist_to_suspicion, math_erfcx, infinity`. See [search scope](README.md#search-scope) for coverage and limits.

## GapUniversal3 guarded internal NaN

**Status:** Reproduced internal NaN; no emitted NaN result in this reproduction.

At 16 KiB of zero input, GapUniversal3 divides `0/sqrt(0)` for an unhit reduced group. A diagnostic copy confirms zero numerator, zero variance, and `autofail=1`. The function returns a finite pass/fail result before appending the affected statistics. This must not be counted as an additional emitted NaN failure. Source: original `src/tests_other.cpp`; no rewrite behavior changed.

### SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `GapUniversal3, reduced_variance, autofail, NaN`. See [search scope](README.md#search-scope) for coverage and limits.

## Bad-input empty histograms in experimental tests

- **BCFN_FF:** the `:freq` guard counts extreme entries, but the scored table
  omits those extremes. `BCFN_FF ones 4 0` reaches an empty three-category G-test
  at level 5; zero input reaches one at level 6 by 8 KiB. NaN raw scores and
  p-values are returned. The separate ramp-input gamma-range error is tracked in [UB015d](UB015d-bcfn-ff-gamma-range.md).
- **LimitedBigGapPrototype:** `ones 64 0` has sufficient expected observations,
  yet its actual cross histogram is empty. The two-category G-test returns NaN.
  The gap histograms also return NaN from 256 KiB. Other fixtures can have usable
  observations; a nominal expected-count guard alone does not establish that.
- **CoupGap:** `zero 256 0` and `ones 256 0` never finish the symbol warmup.
  At 256 KiB the 65,536-bin histogram is still empty. Its G-test returns NaN,
  and calibration rejects it before a `TestResult` is appended.

These reproduce the empty G-test mechanism in [UB015a](UB015a-empty-g-test.md).
No experimental test implementation is added by this fix.

Disclosure search for the experimental empty-histogram cases is retained in
[UB015a](UB015a-empty-g-test.md#sourceforge-disclosure); no exact public
NaN/cause match was found in that search.

### Rewrite finite-score overflow handling

The rewrite also guards overflow when squaring a finite scaled normal score
(for example, a raw magnitude of `1e200`). It returns signed infinite suspicion
and hence p=0 for the positive direction and p=1 for the negative direction.
This is a rewrite robustness correction, not evidence of a new upstream defect
or a demonstrated NS3 byte-stream trigger. Checks cover both signs near the
squaring boundary and through the largest finite f64 value.

### Finite DC7 tail cancellation observation

The preserved DoF-4 expression forms the CDF and then subtracts it from 1.
At chi-square 100, an f64 scalar evaluation returns 0 while the equivalent
upper-tail expression `exp(-50) * 51` is approximately `9.84e-21`.
This loses finite tail information and can overstate failure severity without
producing NaN. The follow-up precision probe calls unchanged original source directly and
confirms this scalar failure. It is not a new byte-stream reproduction. A direct-tail
correction was not included in the Gap fix. Since November 12, 2026, default
mode evaluates the survival probability directly, with a log form for subnormal
tails, and combines DC7 component log-probabilities before converting to an
ordinary probability. `--reference-compatible` retains the preceding finite
arithmetic. Infinity handling remains corrected in both modes. See
[D020](../departures-from-upstream.md#d020--stable-default-g-test-and-dc7-tails).

The same gamma family loses small lower-tail probabilities: at DoF=2,
chi-square=1e-20 returns 0 instead of about 5e-21. Use `-expm1(-chisquared/2)`
for that CDF, direct survival formulas for the other tail, and retain a log-tail
or suspicion during probability combination. Converting an upper-tail CDF
that already rounded to 1 back to a probability cannot recover its lost bits.

## November 13 retained DC7 log tails

Improved mode now carries the direct signed log-tail through reporting as well
as through component combination. At chi-square statistic 1600 the binary64
survival probability underflows to zero, but suspicion remains approximately
-1143.5103742787621. Near zero, a centered series and expm1 retain the complementary
tail. Reference mode retains the prior result calculation. See the
[numerical policy](../numerical-policy.md) and its scalar/stream coverage limits.

## November 13 extreme DC7 component combination

**Status:** Confirmed rewrite source limitation with independent scalar controls;
no new original byte-stream reproduction is claimed.

The retained log-probability path still reconstructed each complementary
probability as 2^(-suspicion-1). For two component suspicions of +1200, both
reconstructed values underflowed, the combined chi-square statistic became zero,
and its suspicion became +infinity. A 1500-digit direct calculation gives a finite
combined suspicion rounding to +2400. This is a further loss of finite tail
information, distinct from the earlier NaN-at-infinity conversion.

Improved mode now uses a scaled logarithmic combination when both component
suspicions exceed 512, without needing either tiny complementary probability or
the combined statistic to remain representable. The discarded terms are bounded
far below binary64 rounding; see the [numerical policy](../numerical-policy.md#dc7-extreme-combination-controls).
The raw statistic and ordinary probability may still round to their endpoints;
reporting retains the finite suspicion. Actual infinite or invalid component
scores retain their infinity/NaN behavior. Reference mode, calibration observations
and vendored source are unchanged. Public disclosure was not searched for this
additional observation.
