# UB045 — Report selection loses precision around tail thresholds

**Status:** Confirmed source comparison and binary64 scalar counterexamples;
no new original input-stream reproduction is claimed.

`.vendor/PractRand/tools/RNG_test.cpp:479` and line 483 compare
`abs(0.5-p)` with `0.5-threshold`. At p=1e-18 and threshold=1e-20, both round to
one half, causing the row to be selected despite p exceeding the tail threshold.
That threshold is outside the rewrite CLI's accepted range; it is a scalar
counterexample, not a valid CLI reproduction. At the supported threshold 1e-10,
the immediately larger binary64 probability is also indistinguishable in the
old subtraction. Converting a retained extreme tail to p=0/1 first introduces
a separate loss of information into the same selection decision.

Improved reporting compares probability tails directly, or compares retained
signed suspicion with the threshold's tail score when available. Exact equality
remains selected. Reference reporting retains the previous subtraction. CLI
threshold limits, probability validation, evaluation labels, weights and `-a`
are unchanged.

`src/report.zig` checks supported threshold neighbors and equality, the tiny
scalar counterexample, both rounded endpoints with finite retained scores,
zero thresholds, unscored and pass/fail results, and all-results selection.
Vendored source is unchanged. Public disclosure was not searched for this
November 13, 2026 record.
