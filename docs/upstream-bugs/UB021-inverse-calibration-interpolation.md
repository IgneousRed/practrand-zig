# UB021 — Raw inverse-calibration interpolation uses the wrong difference

**Status:** Confirmed separate numerical defect found during the NaN audit;
its output in the reproduction is finite. No rewrite behavior was changed.

Both `RawTestCalibrationData_117::index_to_sample` and the 129-entry version in
`tests_core.cpp` use `low + high * fraction`. Linear interpolation requires
`low + (high - low) * fraction`. The scalar probe sets a valid monotone table
`table[i] = i` and calls `index_to_sample(1.5)`: both functions return **2**,
where interpolation gives **1.5**. This is separate from [UB019](UB019-brank-inverse-endpoint.md)'s zero-slope
endpoint NaN and from the `SampleSet` interpolation overflow in [UB018b](UB018b-sampleset-percentile.md). Inverse
calibration is outside the rewrite's implemented CLI subset.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `RawTestCalibrationData, index_to_sample, low + high * fraction, interpolation`. See [search scope](README.md#search-scope) for coverage and limits.
