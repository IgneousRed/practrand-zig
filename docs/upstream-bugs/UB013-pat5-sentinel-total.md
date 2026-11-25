# UB013 — Pat5 global match total includes uninitialized-pattern sentinels

**Status:** Confirmed source arithmetic; suspected defect, intent unresolved.
The port preserves it.

Pat5 initializes each pattern's `total_count` to -1, then `get_results` sums all
patterns into `total_matches`, including those not initialized. With one active
pattern and seven uninitialized patterns, the global total is seven below the
number of counted matches. This affects the global minimum-sample check and the
sample count supplied to histogram simplification. Original evidence is in
`Pat5::init` and `Pat5::get_results` in `src/tests_other.cpp`.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `Pat5, total_matches, total_count -1, uninitialized patterns`. See [search scope](README.md#search-scope) for coverage and limits.
