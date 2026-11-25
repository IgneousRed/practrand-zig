# UB018b — SampleSet percentile interpolation overflows at an exact finite sample

**Status:** Reproduced with finite inputs; calibration/research helper, not a new byte-stream battery failure.

`get_result_by_percentile` has a separate interpolation overflow. For the sorted
finite samples `{-DBL_MAX, -DBL_MAX, DBL_MAX, DBL_MAX}`, percentile `0.375` lands
exactly on the second sample. Its formula still forms the difference to the next
sample, which overflows, then multiplies that infinity by zero. The returned
percentile is NaN instead of `-DBL_MAX`. The reproduction is in the retained scalar probe. These helpers are not implemented as part of the rewrite's CLI.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `SampleSet, get_result_by_percentile, DBL_MAX, interpolation overflow`. See [search scope](README.md#search-scope) for coverage and limits.
