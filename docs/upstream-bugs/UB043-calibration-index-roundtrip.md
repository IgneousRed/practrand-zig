# UB043 — Calibration loses local fraction bits in its index round trip

**Status:** Confirmed source pattern and scalar rounding counterexample; no new
full-stream failure is claimed.

`RawTestCalibrationData_129::sample_to_index` in
`.vendor/PractRand/src/tests_core.cpp:161` adds an integer interval index to the
local interpolation fraction. `index_to_pvalue` at line 195 subtracts the integer
again. For interval 15 and local fraction 1e-16, binary64 rounds the first sum to
15 and loses the fraction. Interpolating from the represented 0.01 and 0.02
endpoints in one fused multiply-add yields 0.010000000000000002; the round trip
yields 0.01.

Improved mode carries the integer index and fraction separately into the final
probability interpolation. Reference mode retains the index round trip and
ordinary multiply/add. Imported observations, interval search, historical 0.001
sample adjustment, and tail slopes are unchanged. The separate inverse formula
issue [UB021](UB021-inverse-calibration-interpolation.md) is not changed here.

`src/statistics.zig` checks the rounding boundary and interval endpoints. The
counterexample is an interpolation-stage control, not a claim that this fraction
was observed in a saved stream. Vendored source is unchanged. Public disclosure
was not searched for this November 13, 2026 record.
