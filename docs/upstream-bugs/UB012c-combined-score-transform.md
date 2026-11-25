# UB012c — NearSeq3 combined raw and processed scores use different transform order

**Status:** Confirmed source behavior; suspected defect or inconsistency, with intent unresolved. The port preserves reported scores.

In original `src/tests_other.cpp`, the `hw:all-` raw score divides the combined normal score by `sqrt(1.25)`,
  while its processed suspicion divides *after* the nonlinear normal-to-suspicion
  conversion. The two fields therefore use different transform order.

This is separate from the reproduced NaNs in [UB004](UB004-bad-rng-nan.md). It is not an approved correction; changing it would change statistical results.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3 combined raw and processed scores use different transform order`. See [search scope](README.md#search-scope) for coverage and limits.
