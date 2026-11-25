# UB012a — NearSeq3 truncates the CDF-derived filter rate

**Status:** Confirmed source behavior; suspected defect or inconsistency, with intent unresolved. The port preserves reported scores.

In original `src/tests_other.cpp`, `do_scoring` stores a CDF-derived `filter_rate` in a `long`, truncating the
  fractional probability before using it in normalization.

This is separate from the reproduced NaNs in [UB004](UB004-bad-rng-nan.md). It is not an approved correction; changing it would change statistical results.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3 truncates the CDF-derived filter rate`. See [search scope](README.md#search-scope) for coverage and limits.
