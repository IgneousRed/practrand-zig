# UB017e — Unused upper incomplete gamma has a finite-input NaN path

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. No helper fix was applied.

Private `math_upper_incomplete_gamma(2.5, DBL_MAX)` returns NaN. `pow(x,1.5)` overflows, then multiplies infinity by `exp(-x)=0`. The audit called the private function by including unchanged `math.cpp` in one translation unit. No caller exists outside its own recursion, so this function is unreachable from the shipped statistical tests. It has no new rewrite compatibility promise.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `math_upper_incomplete_gamma, overflow, pow, incomplete gamma`. See [search scope](README.md#search-scope) for coverage and limits.
