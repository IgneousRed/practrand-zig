# UB033 — Normal suspicion loses its first-order term near zero

**Status:** Confirmed operation-level cancellation in the original expression;
no new failing RNG stream is claimed.

`math_normaldist_to_suspicion` in `.vendor/PractRand/src/math.cpp:1128` forms
`-(log(erfcx(x))-x*x)/ln(2)`, where `x=norm/sqrt(2)`. Its small-x erfcx path
forms `(1-erf(x))*exp(x*x)`. At `norm=1e-18`, rounding erfcx to one leaves
about 7.213475204444817e-37 rather than 1.1511040990721626e-18. The control is
`sqrt(2/pi)/ln(2)*norm`; omitted higher-order terms are negligible here.

Improved mode uses the analytic linear limit for tiny normal inputs and
`-log1p(-erf(x))/ln(2)` with a rational erf approximation near zero. The current
piecewise rational/log-tail kernel and asymptotic extension are documented in
[UB023's follow-up](UB023-normal-cdf-erf-cancellation.md#november-13-moderate-normal-tail-precision).
Only reference mode retains the preceding continued-fraction implementation.
This near-zero mechanism is distinct from UB023's large-argument erf cancellation;
these fixes do not claim to repair that unused upstream large-argument path.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
