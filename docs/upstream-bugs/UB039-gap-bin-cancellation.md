# UB039 — Gap bin probabilities subtract nearby powers

**Status:** Confirmed source expression; scalar loss measured for binary64
evaluation. Original long-double behavior depends on the platform.

`.vendor/PractRand/src/tests_other.cpp:44` implements `gap_probs` as
`q^first - q^(last+1)` using long-double intermediates. Gap16 calls it at line 308
with q=65535/65536. For first=400 and width=1, evaluating this expression in
binary64 has relative error around -3.54e-12 against a 110-digit Decimal control.
The rewrite's reference table retains its previous binary64 expression. The
scalar observation does not establish the same error on x86 extended precision.

Improved mode uses `exp(first*logq) * -expm1(width*logq)`, where
`logq=log1p(-1/65536)`. Independent controls cover narrow and wide bins at several
scales. Bin boundaries, startup fractions and merging are unchanged; normalization
arithmetic was subsequently improved as recorded in [UB047](UB047-gap-startup-normalization.md); both cached and fallback preparation select the run's policy.

Checks live in `src/battery.zig`. This is distinct from the upstream rounding-to-NaN
case in [UB006](UB006-gap16-rarity-nan.md). No new original battery failure is
claimed. Vendored source is unchanged. Public disclosure was not searched for
this November 13, 2026 record.
