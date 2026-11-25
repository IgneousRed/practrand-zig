# UB017d — Log-factorial wraps its maximum unsigned argument

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. No helper fix was applied.

`math_factorial_log(UINT64_MAX)` increments its argument with `a += 1`, wrapping it to zero. The following reciprocal/logarithm expressions yield NaN. This is a reproduced boundary helper input, not a demonstrated byte-stream state. Source: original `src/math.cpp`; retained scalar probe.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `math_factorial_log, UINT64_MAX, unsigned wrap`. See [search scope](README.md#search-scope) for coverage and limits.
