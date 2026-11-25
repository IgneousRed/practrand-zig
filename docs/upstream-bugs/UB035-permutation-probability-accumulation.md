# UB035 — Permutation probability enumeration accumulates rounding error

**Status:** Confirmed original-source repeated-rounding mechanism; an independently
enumerated scalar model exhibits the normalization error. No new stream failure.

The original LPerm setup in `.vendor/PractRand/src/tests_other.cpp:7821` enumerates
40320 permutations and repeatedly adds `1.0/40320` to 128 category probabilities.
Independent enumeration of the same comparisons gives a compensated base total
about 0.999999999999997; counting categories in integers and dividing once gives
1.0 at binary64 precision. The largest base-category difference is about 1.32e-16.
Products of the base probabilities feed the 32768-bin model.

Improved mode counts categories exactly before one division per category. The
imported empirical split ratios remain untouched. Reference mode retains repeated
floating-point increments. The model test checks the improved total and retains
an explicit check for the reference model's historical deficit.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
