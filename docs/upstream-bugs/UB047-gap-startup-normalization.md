# UB047 — Gap startup normalization cancels nearly unit discarded mass

**Status:** Source-confirmed expression; binary64 scalar loss measured. No new
original full-stream failure is claimed.

`.vendor/PractRand/src/tests_other.cpp:282` accumulates discarded startup mass in
a double and divides retained probabilities by `1-lopped`. The rewrite previously
used the same summation/subtraction structure. A binary64 scalar reproduction of
the rewrite formula has about 1.7e-12 relative denominator error at three blocks
against 110-digit arithmetic on its represented inputs. This is not a measurement
of the original's platform-dependent base probability construction.

Improved mode accumulates retained products with compensation and adds the
represented base-model residual `1-sum(p)`. The denominator still represents
`1-sum(p*fraction)`; this is not a silent renormalization. Reference mode retains
its old products, summation and subtraction. Bin boundaries and fractions remain.
Independent rational geometric controls check startup-normalized probabilities.

This is distinct from base-bin cancellation in [UB039](UB039-gap-bin-cancellation.md).
Vendored source and calibration are unchanged. Public disclosure was not searched
for this November 13, 2026 record.
