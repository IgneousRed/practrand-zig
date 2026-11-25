# UB032 — P-value-to-suspicion cancellation near one half

**Status:** Confirmed operation-level cancellation in the original expression;
no new failing RNG stream is claimed.

`TestResult::pvalue_to_suspicion` in `.vendor/PractRand/src/tests_core.cpp:44`
uses `log(p)/log(2)+1`. For binary64 `p=0x1.fffffffffffffp-2`, the expression
returns approximately -2.220446049250313e-16; evaluating `ln(2*p)/ln(2)` with
110-digit Decimal gives -1.6017132519074589e-16. The subtraction loses significant
relative accuracy close to the neutral score.

Improved mode uses `log1p(2*p-1)/ln(2)` for the bounded near-half interval.
Far tails retain the logarithm of p so forming `2*p-1` cannot round to -1.
Reference mode keeps the original expression, including calibration conversion.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
