# UB006 — Folded Gap-16:C: reference NaN, rewrite finite

**Status:** Confirmed upstream ordered-rarity numerical defect; corrected in
the rewrite as described below. The lost historical fixture is not revalidated.

A historical `stdin8 -tf 1` capture with checkpoints every 1 MiB made
untouched x86-64 PractRand abort at 22 MiB with
`test=[Low1/8]Gap-16:C`, `pvalue=nan`, exit 1. The native ARM64 rewrite continued
with a finite result. That original fixture and its captures are no longer retained.

A new independent reproduction uses the unchanged `Gap16` class, `arbee` seed 1
input, and results requested after 2,816 blocks: **2,883,584 bytes (2.75 MiB)**.
That is the amount a 1/8 folding receives at a 22 MiB root checkpoint. A and B
remain finite; C has NaN in raw, processed, p-value, and suspicion fields.
The retained probe command is `upstream-nan Gap16 random 2816 0`.

In `math.cpp`, ordered `rarity_test` first computes a mean using forward
cumulative probabilities. Rounding takes the bin midpoint above one. A diagnostic
copy prints `p=1.0000000000000002`, bin 24052, probability
`3.8538025716949367e-16`, followed by seven more offending tail bins.
`-log(p)-log(1-p)` then evaluates a negative logarithm argument. The later score
cap only checks `score > MAX_SCORE`, which cannot catch NaN. The reversed tail
pass does not repair the already-poisoned mean. This reproduction establishes
an upstream defect independently of the lost historical stream; it does not
establish what every rewrite/platform returns for every affected probability table.

See [departure D008](../departures-from-upstream.md#d008--gap-16c-non-finite-reference-result).
Reference equivalence at the historical checkpoint is still not claimed.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

No exact cause match found. [Ticket #24](https://sourceforge.net/p/pracrand/bugs/24/) concerns restoring Gap16 warmup state, a different mechanism. See also the [historical NaN context](README.md#historical-nan-reports).

Search terms: `Gap-16:C, rarity_test, cumulative probability rounding, NaN`. See [search scope](README.md#search-scope) for coverage and limits.

## Rewrite correction

Ordered rarity scoring now returns its existing cap of 35 when a cumulative
midpoint rounds to or beyond either endpoint, before evaluating logarithms.
The limiting score at these endpoints is infinite and would already be capped;
interior probabilities retain the existing expression. All three scoring passes
use the same rule. This fixes model rounding rather than replacing a test's NaN
with a statistical failure.

Checks cover a synthetic cumulative overshoot and finite rarity scoring of the
rewrite's Gap model at 2,816 blocks. The model check uses synthetic expected
counts, not the lost historical byte stream. Empty/zero-variance model behavior
remains separately tracked in [UB015b](UB015b-degenerate-rarity.md).
