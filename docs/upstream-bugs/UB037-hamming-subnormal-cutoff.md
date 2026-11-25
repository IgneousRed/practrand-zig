# UB037 — Hamming probabilities discard representable subnormals

**Status:** Confirmed original-source cutoff and exact scalar counterexample;
no new input-stream failure is claimed.

The scaled recurrence in `.vendor/PractRand/src/math.cpp:1290` only calls ldexp
when the exponent exceeds -1070. For 1074 bits, the exact zero-weight probability
is 2^-1074, the smallest positive binary64 value. The original branch stores zero.
The next probability is exactly 1074*2^-1074.

Improved mode uses Zig's frexp/ldexp and lets binary64 rounding determine
underflow, with a compensated cumulative sum. Reference mode retains the cutoff
and original target-dependent intermediate precision. Exact bit-pattern tests
cover the first two probabilities and their cumulative value, plus a small
binomial distribution. This removes one avoidable cutoff, not the unavoidable
underflow of probabilities smaller than the binary64 range.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
