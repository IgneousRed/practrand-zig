# UB017f — CLI formatting evaluates an unused NaN at endpoint p-values

**Status:** Reproduced original helper behavior; byte-stream reachability is stated separately. No helper fix was applied.

In original `tools/RNG_test.cpp`, `print_result` obtains infinite suspicion for p=0 or p=1 and computes `dec - ceil(dec)` in its significand formula. That expression is infinity minus infinity. Direct calls to the unchanged formatter at `-O0` raise the floating-point invalid flag at both endpoints; p=0.5 does not. The endpoint branch prints a literal 0 or 1, so the internal NaN is not a reported p-value. At `-O2`, the compiler eliminates the unused computation and no invalid flag is observed. This is a guarded, compiler-dependent expression, not an additional emitted test failure.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `print_result, endpoint p-value, dec - ceil(dec), NaN`. See [search scope](README.md#search-scope) for coverage and limits.
