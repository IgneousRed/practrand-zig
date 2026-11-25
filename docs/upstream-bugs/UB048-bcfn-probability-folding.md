# UB048 — BCFN folds rounded full-width probabilities into smaller models

**Status:** Source-confirmed rounding opportunity and independent scalar evidence;
not a reproduced complete original report failure.

`.vendor/PractRand/src/tests_core.cpp:2219` constructs Bernoulli probabilities with
log/exp, then calls `truncate_table_bits` before its calibrated G-test. The rewrite
likewise accumulated up to 512 entries per effective bin. A binary64 reproduction
of one four-bit folded model differed by about 4.3e-15 relative from a 110-digit
Bernoulli marginal using the represented p1 input.

Improved mode constructs each effective-width marginal directly from the existing
balance constant: 2^-bits * (1-b)^ones * (1+b)^(bits-ones). log1p preserves the
small balance correction; ldexp applies the exact binary scale outside exp.
Independent controls use direct high-precision powers. Original balance constants,
count folding, sample selection and calibration remain unchanged. Reference mode
keeps the full-width table and original folding order. No fixture is regenerated.

Vendored source is unchanged. Public disclosure was not searched for this
November 13, 2026 record.
