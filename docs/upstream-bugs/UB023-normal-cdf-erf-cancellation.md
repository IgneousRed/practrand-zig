# UB023 — Error-function cancellation corrupts normal and chi-square CDFs

**Status:** Confirmed original-source scalar failures.

Original `math.cpp`'s private `math_erf` uses an alternating power series through
arguments just below 8. Cancellation destroys its result in that range.
`math_normaldist_cdf(-9)` returns about -0.1427611282 instead of 1.1285884e-19;
`math_normaldist_cdf(-10)` returns 3881.46365 instead of 7.6198530e-24.
The CDF wrapper has no active caller outside its definition in the searched
shipped source; its `non_uniform.cpp` use is commented out.

The same private erf is actively used by half-integer regularized gamma.
`math_chisquared_to_pvalue(64,1)` returns 0.99992734637 instead of approximately
0.9999999999999988. At (120,1) it returns 0 instead of a value rounding to 1.
Clamping masks the invalid intermediate instead of fixing it. A grid of 16,001
chi-square inputs from 0 to 160 at step .01 had 3,089 decreasing adjacent results.
NearSeq2 and BCFN_FF have active gamma-conversion callers; BRank's chi-square
branch is constant-false and does not establish reachability. This is not a
new demonstrated input-stream reproduction.

Use standard erf/erfc rather than this alternating series, and evaluate the
needed gamma tail directly. General half-integer gamma also needs stable
recurrences; fixing erf alone does not cure every subtraction in gamma.
The normal-to-suspicion routine switches to a different continued fraction
before this unstable region: its tested moderate inputs matched erfc controls.
No production rewrite behavior changed in this audit.

## November 13 moderate normal-tail precision

The earlier moderate-input agreement did not establish near-ulp accuracy. The
normal-suspicion helper uses `1-math_erf(x)` below x=2. A binary64 reproduction
at x=1.9935 gives a suspicion approximately 3.9e-13 above a 110-digit control,
roughly 440 binary64 spacings at that magnitude. This is an expression-level
observation, not a new full-stream failure in the original executable.

Improved mode now uses a pure-Zig fdlibm-derived rational approximation, evaluated
in logarithmic form in the tail, with a linear subnormal limit and a bounded
positive-real asymptotic expansion beyond the ordinary erfc underflow range.
Reference mode retains the old series/continued fraction. The kernel's source,
license, adaptations and validation limits are documented in the
[numerical policy](../numerical-policy.md#normal-tail-kernel-provenance).
Forty-one independent high-precision controls cover all regimes and adjacent
boundary inputs; a 16,384-point grid checks monotonicity. This does not claim
correct rounding for all inputs or fix the unimplemented original gamma callers.
Public disclosure was not searched for this follow-up.

## Reproduction and disclosure status

See the retained [precision probe](../../test/upstream_precision.cpp) and
[audit commands and scope](../precision-audit.md). Original source is unchanged.
Public disclosure was not searched for this new record; the older November 1
search does not establish this issue’s disclosure status.
