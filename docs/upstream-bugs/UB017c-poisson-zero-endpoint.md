# UB017c — Poisson PMF returns NaN for the degenerate zero endpoint

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. No helper fix was applied.

`math_poisson_pmf(0, 0)` computes `log(0) * 0` and returns NaN. The mathematically valid degenerate Poisson endpoint has probability 1. Tested Birthday callers guard zero lambda before reaching it, so this is a direct helper reproduction, not a demonstrated Birthday stream failure. Source: original `src/math.cpp`; retained scalar probe.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `math_poisson_pmf, lambda=0, zero endpoint`. See [search scope](README.md#search-scope) for coverage and limits.
