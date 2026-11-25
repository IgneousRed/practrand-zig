# UB008a — Help claims zero or negative thresholds can disable filtering

**Status:** Confirmed documentation/interface mismatch. The rewrite follows verified source behavior for implemented features and documents its subset.

Help suggests zero/negative thresholds can disable filtering, but parsing
rejects `-e 0` and `-p 0`.

Evidence: feature inventory and CLI/source probes.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `Help claims zero or negative thresholds can disable filtering`. See [search scope](README.md#search-scope) for coverage and limits.
