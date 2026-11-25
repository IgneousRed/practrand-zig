# UB044 — Hamming scores take logarithms after CDF underflow

**Status:** Confirmed source/representation limitation and exact scalar case;
rewrite scoring-state integration is covered, but no new original stream failure
is claimed.

`.vendor/PractRand/src/tests_other.cpp:5485` scores a Hamming weight as
`-log(cdf[hw])`. At zero weight in an 8192-bit model, the exact CDF is 2^-8192.
The binary64 CDF underflows, although its logarithmic score is the finite value
8192*ln(2), approximately 5678.261703147072. NearSeq3 constructs models of this
size. This differs from [UB037](UB037-hamming-subnormal-cutoff.md): removing the
arbitrary cutoff cannot make 2^-8192 representable as a binary64 probability.

Improved models keep a compensated CDF scaled to the recurrence's current
exponent, and retain its logarithm for underflowed/subnormal tails. Ordinary
CDFs and threshold decisions remain unchanged; ordinary-range scores still use
the same CDF. Reference models retain the previous representation and scores.

`src/statistics.zig` checks exact zero/one-weight formulas, subnormal CDFs,
symmetry and monotonicity. A synthetic NearSeq3 scoring-state control checks
finite sample and pair scores where reference scores are infinite, with identical
sample/pair counts. This is not a retained byte-stream reproduction. It does not
change NearSeq3's threshold-exhaustion or invalid-result handling. Vendored source
is unchanged. Public disclosure was not searched for this November 13, 2026 record.
