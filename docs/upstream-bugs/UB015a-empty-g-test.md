# UB015a — Empty histograms can reach G-test scoring

**Status:** Reproduced upstream NaNs in compiled experimental classes. These
classes are outside the rewrite's implemented subset; no correction is authorized.

`g_test` and `g_test_flat` end with a term containing `total * log(total)`.
`G_TEST::get_result` does the same. With no observations this evaluates
`0 * -infinity`, yielding NaN. The scalar driver reproduces all three with a
normalized two-bin probability model and zero counts. Their use is unsafe when
a caller's nominal-sample guard passes but its actual scored histogram is empty.

Bad-input BCFN_FF, LimitedBigGapPrototype and CoupGap cases are consolidated
in [UB004](UB004-bad-rng-nan.md#bad-input-empty-histograms-in-experimental-tests).

- **SimpleClassifyWord:** `empty 0 1` unconditionally scores an empty histogram.
  It returns a NaN result at zero bytes. The four nonempty fixtures returned
  finite results through 1 MiB, so this is specifically an empty-state failure
  in the audited cases.

Diagnostic copies confirmed zero observed totals and the category counts above.
The empty case of `g_test_flat_merge_normal` is guarded and returns zero.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

General NaN context is recorded in [the search overview](README.md#historical-nan-reports). A [2016 report](https://sourceforge.net/p/pracrand/discussion/366935/thread/2b43b548/1ba9/) identifies bad BCFN_FF frequency p-values, but neither NaNs nor this empty-histogram cause.

Search terms: `G_TEST, g_test, g_test_flat, CoupGap, BCFN_FF, LimitedBigGapPrototype, SimpleClassifyWord, empty histogram`. See [search scope](README.md#search-scope) for coverage and limits.
