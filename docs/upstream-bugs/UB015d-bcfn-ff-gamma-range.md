# UB015d — BCFN_FF ramp input aborts with invalid gamma parameters

**Status:** Reproduced upstream abort; root cause unresolved. The experimental class is outside the implemented rewrite subset.

The isolated driver, using repeated 0..255 byte ramps and default BCFN_FF parameters, aborts at 2 KiB with `math_regularized_gamma_function - parameters out of range`. The process exits 1. It returns no NaN result row before that abort. This differs from the empty scored histogram on zero/all-ones input ([UB015a](UB015a-empty-g-test.md)). Reproduce with `upstream-nan BCFN_FF ramp 2 0`; see the audit for initialization and build settings.

No correction or new rewrite handling was applied.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

The [2016 frequency-p-value report](https://sourceforge.net/p/pracrand/discussion/366935/thread/2b43b548/1ba9/) does not identify this gamma-parameter abort.

Search terms: `BCFN_FF, freq, gamma parameters out of range`. See [search scope](README.md#search-scope) for coverage and limits.
