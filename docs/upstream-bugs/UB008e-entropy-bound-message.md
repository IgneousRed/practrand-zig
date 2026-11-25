# UB008e — Entropy-wrapper range diagnostic excludes a permitted endpoint

**Status:** Confirmed documentation/interface mismatch. The rewrite follows verified source behavior for implemented features and documents its subset.

The entropy-wrapper range error says `maxlength < 500`, while the source
validation permits 500 (`tools/SeedingTester.h`).

Evidence: feature inventory and CLI/source probes.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `Entropy-wrapper range diagnostic excludes a permitted endpoint`. See [search scope](README.md#search-scope) for coverage and limits.
