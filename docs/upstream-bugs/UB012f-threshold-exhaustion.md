# UB012f — NearSeq3 can access a negative CDF index before rejecting threshold exhaustion

**Status:** Source-confirmed unsafe evaluation order and reproduced exhaustion error; no independent memory-safety instrumentation result is claimed.

The threshold-exhaustion path calls `do_scoring` before checking whether its returned threshold is negative; scoring can access `cdf[filter_threshold]` with index -1 first. The rewrite checks exhaustion before that access and returns the corresponding explicit error.

Historical diagnostic drivers passed the earlier NS3 NaN checks, reached 16 KiB of zero input, and aborted while feeding toward 32 KiB with a threshold-below-zero error. The isolated zero-input audit also reaches threshold exhaustion after earlier NaN rows; see [audit coverage](../nan-audit.md). These failures are distinct from the non-finite-result conversion in [UB004](UB004-bad-rng-nan.md).

The reproduced failure behavior is retained without intentionally reproducing undefined memory access. Source: NearSeq3 in `src/tests_other.cpp`.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `NearSeq3, tighten_threshold, do_scoring, filter_threshold, threshold dropped below 0`. See [search scope](README.md#search-scope) for coverage and limits.
