# UB040 — Birthday rounds away small integer residuals

**Status:** Confirmed conversion-level counterexample; synthetic scoring state,
not demonstrated stream reachability.

`.vendor/PractRand/src/tests_core.cpp:4655` forms
`(num_duplicates-lambda)/sqrt(lambda)`. Converting count=2^53+1 to binary64 before
subtracting lambda=2^53 produces zero instead of one. This affects the raw
normalized score and the value used to select/sign the tail approximation. It is
distinct from subsequent logarithmic cancellation in
[UB036](UB036-birthday-tail-cancellation.md).

Improved mode splits the integer conversion and subtracts the represented
expectation before combining low bits. Raw scoring, branch selection and the
centered log-tail helper use the same residual. Reference mode keeps the previous
conversion and expression. No expectation, threshold or calibration is changed.

`src/statistics.zig` checks residuals at 2^53 and the u64 endpoint.
`src/battery.zig` checks a synthetic scoring state: improved raw score is
1/sqrt(2^53), with the corresponding suspicion sign; reference raw score remains
zero. No input stream producing that state has been retained. Vendored source is
unchanged. Public disclosure was not searched for this November 13, 2026 record.
