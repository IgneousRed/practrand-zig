# UB024 — G-test subtraction loses small statistics for large nonempty counts

**Status:** Confirmed original-source scalar defect with normalized models.

For probabilities {.5,.5} and counts {1,000,000,001,999,999,999}, original
`g_test` returns -4.6119093895e-6, although the true statistic is approximately
2e-9 and cannot be negative. `g_test_flat` gives 2.8386712074e-6 on the same
counts. At n=1e15 with counts {n+1,n-1}, `g_test` gives -2.71875 and the flat
variant gives 4.7421875 instead of about 2e-15. These are scalar synthetic
histograms, not evidence of incorrect complete battery reports at those lengths.

The routines subtract two terms of order N log(N). The implementation already
uses long double internally; changing its data type is not the proposed fix.
Use a per-bin deviance sum, centered at expected counts, with log1p and a
small-relative-deviation series for `(1+d)*log1p(d)-d`. Include the linear
residual term when represented expected totals differ from the observed total;
do not assume a rounded probability model sums exactly to one. Compensated
summation can reduce the remaining accumulation error. Merely clamping a
negative answer hides the precision loss.

Both helpers are used by core and experimental tests, including Gap and DC
variants. The retained probe additionally exercises G_TEST; exact magnitudes
are platform-dependent. No rewrite correction was made by the original audit.

## Rewrite handling

Since November 12, 2026, default mode uses centered deviance terms, compensated
sums and the represented probability model's linear normalization residual.
Product/division rounding and integer conversion remainders are retained so
one-count deviations survive above 2^53. It neither renormalizes models nor
clamps negative statistics. Independent 110-digit decimal controls check both
flat and explicit models, zero bins and model-total residuals.
`--reference-compatible` retains the preceding subtraction-based evaluation.
See [D020](../departures-from-upstream.md#d020--stable-default-g-test-and-dc7-tails).
These scalar checks do not claim a newly reproduced full upstream battery failure.

## Reproduction and disclosure status

See the retained [precision probe](../../test/upstream_precision.cpp) and
[audit commands and scope](../precision-audit.md). Original source is unchanged.
Public disclosure was not searched for this new record; the older November 1
search does not establish this issue’s disclosure status.

## Moderate deviations

The improved kernel additionally uses v=d/(2+d) and the convergent odd series
for log(1+d)=2*atanh(v) when 0.01<=abs(d)<=0.5. Its linear term is cancelled
algebraically, and the omitted-series bound controls termination. Outside this
range, explicit FMA avoids an extra rounding before subtracting the linear term.
Independent 110-digit controls cover both boundaries. Reference mode is unchanged.
