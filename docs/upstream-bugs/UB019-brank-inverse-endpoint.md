# UB019 — BRank inverse calibration produces NaN at p-value zero

**Status:** Reproduced inverse-helper endpoint defect; no observed failure in
BRank's forward statistical reporting from this cause.

The calibration probe reads all 756 declared 117/129 table entries and queries
the manager at each name/length. It calls both conversion directions at nine
finite samples from `-DBL_MAX` through `DBL_MAX`, at both infinities, and calls
`pvalue_to_sample` at 0 and 1: 18,144 conversion calls in total. There are six
underlying failing cases: `BRank` sizes **3, 4, 5, 6, 8, and 10**.

For those sizes the lower fitted slope is zero. `pvalue_to_sample(0)` converts
zero to negative infinite suspicion, then `suspicion_to_sample` computes
`-infinity * 0 + low_b`, yielding NaN. Direct negative-infinity suspicion gives
the same six failures, so the audit records twelve NaN calls, not twelve distinct
calibration defects. All finite-input conversion calls in this grid returned
non-NaN values. Table-name/length collisions use the manager's selected table;
this does not independently validate superseded declarations. No inverse
calibration behavior was added to or changed in the rewrite.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `BRank, pvalue_to_sample(0), zero slope, inverse calibration`. See [search scope](README.md#search-scope) for coverage and limits.
