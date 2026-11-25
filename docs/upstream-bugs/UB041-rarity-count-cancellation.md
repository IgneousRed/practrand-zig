# UB041 — Rarity multiplies rounded centered weights by large counts

**Status:** Confirmed source mechanism and scalar stress case; no new original
full-stream failure is claimed.

`.vendor/PractRand/src/math.cpp:628` computes rarity's mean and then accumulates
`(weight-mean)*count` in both ordered and unordered paths. Even compensating the
sum cannot recover errors already introduced in the centered weights/products.
For probabilities [1/8,3/8,1/2] and counts [k,3k,4k], the exact statistic is zero;
a binary64 probe of the previously compensated unordered expression gives about
-8.31e-11 at k=1e12 and 3.98e-10 at k=1e15.

Improved mode forms `sum(weight*(count-N*p))`, recovering integer and product
residuals before cancellation. Ordered rarity retains its forward mean and reverse
upper-half scoring convention. Their model-bias correction is retained for
non-unit probabilities; probabilities are not silently renormalized. Reference
mode retains the old centered-weight products and addition order.

The correction itself uses a centered log1p ratio for nearby uncapped weights.
Directly subtracting the two weights would introduce another cancellation:
with the third probability 1/2+2^-45 and counts [1e18,3e18,4e18], the exact
ordered statistic is about -0.0004625969117157675. A binary64 probe of the direct
weight subtraction contributes about 5.91e-7 error to that statistic. Controls
cover both signs of this tiny model-mass departure using exact represented inputs.

Controls in `src/statistics.zig` check exact balance, a one-count displacement at
counts above 2^53, and ordered/unordered non-unit formulas. The deliberately
non-unit [.125,.375,.4] stress model is outside the original helper's accepted
normalization tolerance; it verifies algebra, not valid upstream execution.
Vendored source is unchanged. Public disclosure was not searched for this
November 13, 2026 record.
