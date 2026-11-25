# UB011 — FPF long-stride nominal sample count appears one below counted windows

**Status:** Suspected discrepancy from source inspection; not established as an
unintended defect. No behavior change is planned on this evidence alone.

For an initial 1 KiB call, the large-footprint FPF/64 loop appears to count 128
windows, while `get_results` uses `(blocks * 8192 - 64) / 64 = 127` nominal
samples. FPF/32 similarly appears to count 255 initial windows versus 254 nominal
samples. Inspect the long-stride loop in original `src/tests_core.cpp` alongside
its result calculation. The formula may be a deliberate calibration convention;
its intent and statistical effect have not been established. Histogram-level
checks and the calibration-generation assumptions should be examined before
classifying or correcting it. Keep this separate from [UB001](UB001-fpf64-checkpoints.md)'s alignment change.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

The [2018 short-FPF discussion](https://sourceforge.net/p/pracrand/discussion/366935/thread/3c6e7916/ccdb/9de3/ef03/) describes calibration used below intended sample sizes. It does not establish this nominal-count discrepancy.

Search terms: `FPF/64, FPF/32, sample count, 127, 128, one below`. See [search scope](README.md#search-scope) for coverage and limits.
