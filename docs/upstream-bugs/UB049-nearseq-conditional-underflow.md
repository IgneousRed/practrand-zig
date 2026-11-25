# UB049 — NearSeq conditional PDF normalization overflows or divides vanished tails

**Status:** Source-confirmed arithmetic limitation and synthetic scoring-state
reproduction; no valid byte-stream reproduction is claimed.

`.vendor/PractRand/src/tests_other.cpp:5597` forms a reciprocal conditioning CDF
and multiplies PDF entries by it. A subnormal CDF can overflow this reciprocal
although PDF/CDF is finite. If both stored probabilities underflow, direct division
alone is insufficient. This is distinct from taking logarithms of an underflowed
CDF in [UB044](UB044-hamming-log-tail-underflow.md).

Improved mode uses ordinary division for normal CDFs. Below that range it starts
with unit relative probability at the threshold, recurs downward using the exact
binomial ratio i/(bits+1-i), and divides by a compensated weight sum. Absolute
probability scale cancels. It retains the original integer filter-rate convention,
score ranges and CDF-based threshold selection. Threshold exhaustion remains the
existing explicit error; degenerate zero-variance states are not given new scores.

Exact integer-binomial controls cover normal, subnormal and zero conditioning
CDFs. A synthetic 4096-bit state at threshold 800 produces finite core/sample/pair
scores without changing the next threshold, sample count or exhaustion behavior.
Reference arithmetic and vendored source are unchanged. Public disclosure was not
searched for this November 13, 2026 record.
