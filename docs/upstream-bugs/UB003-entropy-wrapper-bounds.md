# UB003 — Entropy-wrapper factory parses both length bounds from one argument

**Status:** Confirmed source defect; preserved by the implemented
`EntropyPoolingTester` expression. Native `-ttep` is implemented with the original
fixed 57-byte interval, which does not expose this factory parsing defect; see
[entropy testing](../entropy-testing.md).

In original `tools/SeedingTester.h`, `EntropyPool_MetaRNG::_factory` reads
both `minlength` and `maxlength` from `params[1]`, ignoring `params[2]`. Normal `-ttep` uses fixed
57-byte strings, which can conceal the problem. Source inspection is recorded in
the compatibility research. A correction would need
explicit compatibility authorization; adding the factory preserves its original
behavior. Retained metadata cases in `test/input-vectors.json` compare
`EntropyPoolingTester(arbee,8,16)` with `(arbee,8,8)`: both identify the
resolved interval as `8to8`.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `EntropyPool_MetaRNG, minlength, maxlength, params[1], -ttep`. See [search scope](README.md#search-scope) for coverage and limits.
