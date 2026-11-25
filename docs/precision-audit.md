# Original PractRand operation-level precision audit

This November 1, 2026 follow-up to the [NaN audit](nan-audit.md) investigates
finite wrong results as well as non-finite errors. The original audit changed
no production statistical code or data types. The later default-only rewrite
handling of G-test, DC7 and the November 13 precision improvements is described
in the [numerical policy](numerical-policy.md) and recorded in
[D020](departures-from-upstream.md#d020--stable-default-g-test-and-dc7-tails).
Original reference provenance remains in
[reference provenance](reference-source.md).

## Method and coverage

Reviewed the statistical portion of original math.cpp (histogram statistics,
factorial/Poisson, gamma, normal transforms, Hamming probabilities, uniformity
and SampleSet), numerical expressions in tests_core.cpp/tests_other.cpp,
calibration/result conversions, reporting, and relevant non_uniform.cpp uses.
A comment-stripped text inventory found 275 lines with numerical function calls
across the searched files. This is a navigation aid, not proof of runtime
reachability: constant-false branches and disabled sections require separate
inspection. BRank's chi-square branch and a NearSeq2 validity branch are such
false positives. Active callers are stated in each issue.

The retained [scalar driver](../test/upstream_precision.cpp) includes unchanged
math.cpp in one translation unit to access private routines, and links the
unchanged original library. It uses the reference builder's x86-64/Rosetta,
Clang, -O3, no-fast-math configuration. It runs no battery and does not demonstrate
new byte-stream failures. No exhaustive claim over configurations, platforms,
integer RNG algorithms, all developer tools, or arbitrary inputs is made.

```sh
python3 -B tools/build_reference.py --driver test/upstream_precision.cpp \
  --output .work/precision-audit/upstream-precision
.work/precision-audit/upstream-precision
```

Output rows contain case, input, original value, and comparison value; the grid
summary is a separate line. The probe reports evidence rather than treating
known original defects as harness failures. Normal controls use standard erf/erfc;
chi-square DoF 2/4 controls use closed forms and expm1. Symmetric G-test controls
use `2/n + 1/(3*n^3)`; omitted terms are negligible for tested n>=1000. Poisson
peak controls use a truncated Stirling series at n>=1000 and are explicitly
asymptotic. Infinity in the erfc-based normal-suspicion control for enormous
arguments reflects underflow of that control's erfc; it is not evidence that
the original's finite log-tail result is wrong.

A 16,001-point grid uses chi-square x=0..160 at .01 spacing and normal z=-x/10.
It found 3,089 chi-square DoF-1 decreases and 3,555 normal-CDF values outside
[0,1]. Those counts describe this build and grid only.

## Findings and improvements

All proposals below keep existing numeric types. Confidence describes the
operation-level diagnosis; stream reachability is a separate qualification.

| Priority | Finding | Operation-level remedy | Evidence / confidence |
|---|---|---|---|
| High | CDF corruption from the original alternating erf series | Standard erf/erfc; stable lower/upper gamma algorithms chosen for the requested tail | [UB023](upstream-bugs/UB023-normal-cdf-erf-cancellation.md), 10/10 |
| High | DC7 upper-tail cancellation; small gamma lower tails vanish too | Direct survival formula for DoF 4; -expm1 for DoF 2 CDF; keep log tails through combination | [UB004](upstream-bugs/UB004-bad-rng-nan.md#finite-dc7-tail-cancellation-observation), 10/10 |
| High | Nonempty G-test loses small results and becomes negative | Per-bin centered deviance, log1p, small-deviation series, compensated accumulation | [UB024](upstream-bugs/UB024-g-test-cancellation.md), 10/10 |
| Medium | GapUniversal3 adjustment rounds a small probability to zero | -expm1(log1p(-p)/N) | [UB025](upstream-bugs/UB025-gapuni-tail-cancellation.md), 10/10 |
| Low runtime impact | Unused upper-gamma integer formula is wrong | Correct integer recurrence/formula, or remove unused helper | [UB026](upstream-bugs/UB026-upper-gamma-integer-formula.md), 10/10 |
| Low runtime impact | Unused normal log-PDF overflows before the answer does | Scale before squaring: -(z*0.5)*z | [UB027](upstream-bugs/UB027-normal-logpdf-overflow.md), 10/10 |
| Conditional | Large-lambda Poisson PMF loses peak precision | Deviance-centered log-PMF or recurrence about the mode | [UB028](upstream-bugs/UB028-poisson-peak-cancellation.md), 9/10 |

Keeping a direct tail or suspicion also avoids converting a finite log-tail to
p=0/1 and then taking its logarithm again. A double CDF cannot encode arbitrarily
small distances from 1; no rearrangement of that already-rounded CDF recovers
the missing information. Callers must request/carry the needed tail.

Existing SampleSet variance/interpolation, empty/degenerate statistics, inverse
calibration and endpoint issues remain linked from the [issue index](upstream-bugs/README.md).
Centered/two-pass variance or Welford updates, overflow-safe interpolation, and
explicit domain handling address these without wider types. Avoid changing the
historical chi-square normalization solely for mathematical convention: its
calibration dependencies make that a separate statistical change.

## Tradeoffs and next work

Direct-tail formulas and expm1/log1p usually add little complexity, but change
reported values and therefore require departure records when implemented.
Centered G-test evaluation needs careful handling of zero counts, impossible
bins, and rounded normalization; it is the larger change. New sums can change
last-bit rounding and may need calibration compatibility checks. Thresholds
that simply clamp errors can conceal these defects rather than improve accuracy.
The strongest implementation candidates are DC7's direct tail and centered
G-test evaluation because both affect the implemented rewrite subset.
