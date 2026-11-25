# UB025 — GapUniversal3 multiple-comparison adjustment loses tiny probabilities

**Status:** Confirmed cancellation in the active expression; scalar reproduction.

In `tests_other.cpp`, GapUniversal3's `:high` result computes
`1 - pow(1 - highest_lbp, 1.0 / (1 << target_lowbits))`.
At highest_lbp=1e-20 and target_lowbits=4 this returns 0 instead of approximately
6.25e-22. Both values are representable in double; forming 1-p loses p first.

Use `-expm1(log1p(-p)/N)` with the existing endpoint conventions.
This preserves the existing mathematical formula; the statistical choice of
this adjustment is not assessed here. The corresponding lowest-order sample
helper `lowest_of_N` has the same subtraction pattern, which can instead use
`-expm1(log(r)/n)` for interior r. That latter path is a research helper.
GapUniversal3 is outside the implemented rewrite subset. No stream reproduction
or production change is claimed.

## Reproduction and disclosure status

See the retained [precision probe](../../test/upstream_precision.cpp) and
[audit commands and scope](../precision-audit.md). Original source is unchanged.
Public disclosure was not searched for this new record; the older November 1
search does not establish this issue’s disclosure status.
