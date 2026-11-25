# UB034 — BRank rounds finite exponential tails to endpoints

**Status:** Confirmed original-source arithmetic limitation; scalar reproduction,
not a new full-stream failure.

The active rarity branch in `.vendor/PractRand/src/tests_core.cpp:3798` constructs
an exponential probability for fewer than sixteen BRank samples and stores
`1-p2` as a probability result. At normalized score 40, the probability rounds
to one, so subsequent suspicion is positive infinity. Its mathematical suspicion
is `40/ln(2) = 57.70780163555854`. The original's negative-score branch also
subtracts from one twice, losing small lower tails.

Improved mode retains the direct signed suspicion through report evaluation,
with the old probability result kind for ordinary presentation. Reference mode
keeps its prior probability calculation. The focused BRank test checks both modes.

## Verification and disclosure

Focused controls live in the rewrite's `src/statistics.zig`, `src/battery.zig`
and `src/permutation.zig`; see [numerical policy](../numerical-policy.md).
The observations are based on source expressions and scalar controls, not a new
execution of the original full battery. Vendored source is unchanged. Public
disclosure was not searched for this November 13, 2026 record.
