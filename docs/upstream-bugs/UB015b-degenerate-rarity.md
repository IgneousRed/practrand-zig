# UB015b — Rarity scoring divides by zero for empty or zero-variance models

**Status:** Reproduced helper behavior; a degenerate rarity model is not evidence of failure in every caller.

`rarity_test_old` and both modes of `rarity_test` also divide by zero for empty
histograms or exactly zero scoring variance; the driver reproduces NaNs with
empty counts and with the flat model `{0.5, 0.5}` / counts `{10, 10}`. A flat
model is degenerate for a rarity statistic, so this alone is not evidence of a
failure in every caller.

No correction was applied. The Gap16 cumulative-rounding defect is tracked separately in [UB006](UB006-gap16-rarity-nan.md).

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `rarity_test_old, rarity_test, empty counts, zero scoring variance`. See [search scope](README.md#search-scope) for coverage and limits.
