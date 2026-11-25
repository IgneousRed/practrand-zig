# UB008c — Birthday suite help does not match the selected test

**Status:** Confirmed documentation/interface mismatch. The rewrite follows verified source behavior for implemented features and documents its subset.

Help describes `-te 10` as a systematically expanding Birthday test, but it
constructs `Birthday64`.

Evidence: feature inventory and CLI/source probes.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

The [2018 Birthday-test discussion](https://sourceforge.net/p/pracrand/discussion/366935/thread/6a1eb94c/) reports that -te 10 selected Rep16; the maintainer acknowledged the selection mistake and said it was fixed for 0.95. The 0.96 mismatch here instead selects Birthday64. The earlier report is related, not an exact match.

Search terms: `Birthday suite help does not match the selected test`. See [search scope](README.md#search-scope) for coverage and limits.
