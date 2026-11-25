# UB022 — FPMulti aborts when its gap product becomes zero

**Status:** Reproduced upstream abort and exact prior public report. The experimental class is outside the implemented rewrite subset.

The isolated zero-input probe terminates with `FPMulti::process - gap product is zero` while feeding its first 1 KiB, before any result checkpoint. The process exits 1; this is an explicit zero-product error, not a NaN row. The ordinary four-fixture audit retains this error and its stderr. Reproduce with `upstream-nan FPMulti zero 1 0`; see the audit for initialization/build settings. The underlying numerical treatment has not been redesigned or fixed.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Disclosed.

Exact match: [SourceForge ticket #18](https://sourceforge.net/p/pracrand/bugs/18/), reported October 7, 2023 by igneous-red; status **open** when checked. It reports the same error with a zero generator and other low-quality generators, and notes that aborting disrupts automation. There are no discussion replies.

Search terms: `FPMulti::process, gap product is zero, zero generator`. See [search scope](README.md#search-scope) for coverage and limits.
