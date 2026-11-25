# UB036 — Birthday large-count log-tail cancellation

**Status:** Confirmed operation-level cancellation; stress parameters have not been
shown to arise in a retained full-stream fixture.

`.vendor/PractRand/src/tests_core.cpp:4657` and its lower-tail counterpart use
`n*log(lambda/n)+n-lambda`. With lambda=1e12 and n=1000004000000 (four standard
deviations), binary64 evaluation gives -8, while 110-digit Decimal gives
-7.9999893333546666... . This is a different expression from the Poisson PMF
recorded in [UB028](UB028-poisson-peak-cancellation.md).

Improved mode centers the expression as `n*(log1p(d)-d)`, with
`d=(lambda-n)/n`, a small-d polynomial, and split integer conversion above 2^53.
A logarithm of the ratio handles extreme negative d without rounding a positive
ratio to zero via `1+d`. The original tail approximation and branch thresholds
remain; this is a numerical fix, not a new Poisson calibration. Reference mode
keeps the original expression. Decimal controls cover both four-sigma tails,
a one-count difference above 2^63, and a far lower ratio.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
