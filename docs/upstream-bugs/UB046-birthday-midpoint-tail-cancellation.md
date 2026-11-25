# UB046 — Birthday midpoint CDF loses precision in its upper tail

**Status:** Confirmed source round trip and rewrite-expression scalar loss;
the original's exact error magnitude has not been remeasured.

`.vendor/PractRand/src/tests_core.cpp:4661` accumulates Poisson probabilities,
adds half the observed mass, and converts the binary64 CDF to suspicion. The
original sums individual PMFs in long double; the rewrite's prior small-lambda
path used a binary64 recurrence. Both first form the lower CDF even when the
upper tail is needed. For lambda=64 and n=95, a binary64 reproduction of the
rewrite's previous expression gives an upper tail with about 1.68e-12 relative
error against a 100-digit Decimal control. This is distinct from large-count
log-tail cancellation in [UB036](UB036-birthday-tail-cancellation.md).

Improved mode computes the smaller midpoint tail directly, preserving
`P(X<n)+P(X=n)/2` and its complement. A compensated PMF recurrence retains
multiplication and division residuals; summation is compensated too. A geometric
bound on the decreasing upper recurrence controls truncation. When skew puts the
lower midpoint CDF just above one half at the mean, scoring switches to the
direct upper tail. Reference recurrence and summation remain unchanged.

Fifteen independent Decimal controls in `src/statistics.zig` cover both tails,
the mean, small lambda and the upper edge of the existing branch. Lambda/norm
branch thresholds, zero-count handling, historical large-count approximations
and calibration are unchanged. No new original full-stream failure is claimed.
Vendored source is unchanged. Public disclosure was not searched for this
November 13, 2026 record.
