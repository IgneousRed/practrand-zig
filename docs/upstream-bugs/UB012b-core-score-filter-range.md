# UB012b — NearSeq3 core scoring and normalization use different filter ranges

**Status:** Confirmed source behavior; suspected defect or inconsistency, with intent unresolved. The port preserves reported scores.

In original `src/tests_other.cpp`, the core-score loop excludes weights at/below `new_threshold` even when the
  call is not filtering, although its normalization range uses `filter_threshold`.

This is separate from the reproduced NaNs in [UB004](UB004-bad-rng-nan.md). It is not an approved correction; changing it would change statistical results.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3 core scoring and normalization use different filter ranges`. See [search scope](README.md#search-scope) for coverage and limits.
