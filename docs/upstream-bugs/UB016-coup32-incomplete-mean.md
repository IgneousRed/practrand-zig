# UB016 — Coup32 reports a mean before completing a set

**Status:** Reproduced raw NaN; compiled experimental class, not implemented in
the rewrite.

`Coup32::get_results` unconditionally computes
`double(set_start_position) / num_complete_sets`. Both are zero before the first
complete set of all 2^32 coupons. The driver reproduces raw NaN for empty input
and every audited nonempty fixture from 1 KiB through 1 MiB. The result is
`TYPE_UNKNOWN`, so `get_pvalue()` returns 0.5 and `get_suspicion()` returns zero.
Consequently the CLI p-value validator would not detect this raw NaN. Its normal
raw formatter also treats unordered comparisons like a very large positive raw
value instead of printing an explicit NaN.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `Coup32, num_complete_sets, set_start_position, 0/0, TYPE_UNKNOWN`. See [search scope](README.md#search-scope) for coverage and limits.
