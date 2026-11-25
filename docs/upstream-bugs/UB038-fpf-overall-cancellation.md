# UB038 — FPF overall nominal G-test cancellation

**Status:** Confirmed source expression and scalar cancellation; no new original
full-stream failure is claimed.

`.vendor/PractRand/src/tests_core.cpp:3128` accumulates
`n*log(n/expected)` directly for the overall FPF statistic. For two nominal
expectations of 1e12 and counts 1e12+1 and 1e12-1, a binary64 expression probe
produces approximately 0.000222044606924987 for twice this sum; 110-digit Decimal
gives approximately 2e-12. This is a separate scoring path from the general
G-test in [UB024](UB024-g-test-cancellation.md).

Improved mode evaluates the centered nonlinear terms and retains `sum(n-E)`
separately. The nominal expectation convention from
[UB011](UB011-fpf-nominal-sample-count.md) is unchanged: observed and expected
totals need not match. The statistic can legitimately be negative under this
convention. Reference mode retains the direct expression and addition order.

`src/statistics.zig` checks balanced counts, counts above 2^63, mixed expectations,
positive and negative total residuals, empty observations and zero expectation.
These are formula controls, not evidence that the stress counts occur in a
retained stream. Vendored source is unchanged. Public disclosure was not searched
for this November 13, 2026 record.
