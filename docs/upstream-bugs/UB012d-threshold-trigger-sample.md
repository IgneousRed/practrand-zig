# UB012d — NearSeq3 inserts the triggering sample without rechecking the new threshold

**Status:** Confirmed source behavior; suspected defect or inconsistency, with intent unresolved. The port preserves reported scores.

In original `src/tests_other.cpp`, `handle_sample` checks the old threshold, tightens it when full, and inserts
  the triggering sample without checking it against the lowered threshold again.

This is separate from the reproduced NaNs in [UB004](UB004-bad-rng-nan.md). It is not an approved correction; changing it would change statistical results.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3 inserts the triggering sample without rechecking the new threshold`. See [search scope](README.md#search-scope) for coverage and limits.
