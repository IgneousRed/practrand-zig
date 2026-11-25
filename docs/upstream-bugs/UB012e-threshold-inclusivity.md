# UB012e — NearSeq3 size paths disagree on threshold inclusivity

**Status:** Confirmed source behavior; suspected defect or inconsistency, with intent unresolved. The port preserves reported scores.

In original `src/tests_other.cpp`, fast sizes accept weights equal to the threshold; the larger-size path uses
  a strict comparison. Whether that difference is intentional is unresolved.

This is separate from the reproduced NaNs in [UB004](UB004-bad-rng-nan.md). It is not an approved correction; changing it would change statistical results.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3 size paths disagree on threshold inclusivity`. See [search scope](README.md#search-scope) for coverage and limits.
