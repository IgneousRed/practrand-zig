# UB026 — Unused integer upper-gamma branch has an incorrect formula

**Status:** Confirmed original-source formula defect in unused private code.

Private `math_upper_incomplete_gamma(2,1)` returns 1 instead of 2/e, and
(2,10) returns 1 instead of approximately 0.0004993992274.
The integer branch omits the highest polynomial term and the exponential and
factorial scaling: for positive integer n, the correct expression is
`(n-1)! * exp(-x) * sum(x^k/k!, k=0..n-1)`.
The zero-argument path also uses the approximate math_factorial helper.

No caller exists outside this helper's own recursion. This is separate from
the unused finite-input overflow in [UB017e](UB017e-unused-upper-gamma-overflow.md).
Deleting the unused routine would remove both hazards; retaining it requires
the proper recurrence with scaling/log evaluation for large arguments.
No rewrite behavior changed.

## Reproduction and disclosure status

See the retained [precision probe](../../test/upstream_precision.cpp) and
[audit commands and scope](../precision-audit.md). Original source is unchanged.
Public disclosure was not searched for this new record; the older November 1
search does not establish this issue’s disclosure status.
