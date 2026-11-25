# UB009 — Error exit statuses can report success for failed requests

**Status:** Confirmed CLI behavior; invalid/unsupported requests intentionally
exit 1 in the rewrite. Some other upstream behaviors remain preserved.

Original 0.96 returns 0 for several invalid numeric/suite/seed requests, missing
input files, and early EOF. Finite `RNG_output` truncation can also diagnose a
problem while returning 0. Consequently, status 0 alone does not prove that the
requested run completed or that the RNG passed.
Evidence: exit-status research and
[departure D004](../departures-from-upstream.md#d004--invalid-and-unsupported-requests-fail-with-status-1).
The rewrite's early-EOF behavior still follows upstream; its invalid-request
status change is explicit rather than presented as a transparent optimization.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `exit status, exit code, early EOF, RNG_output truncation`. See [search scope](README.md#search-scope) for coverage and limits.
