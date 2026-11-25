# NaN audit of the 0.96 statistical implementation

The November 1, 2026 audit reproduced NaN paths in **seven test families with
nonempty byte streams**, plus `SimpleClassifyWord` before any input. The table
lists reproduction checkpoints, not proven minimum failing lengths. Byte counts
are bytes delivered to the individual test, before any external folding.

| Test / result | Input and checkpoint | Observed behavior | Issue |
|---|---|---|---|
| NearSeq3 `NS3[4:hw:both]` | Zero, 2 KiB | Infinite raw score; NaN processed suspicion/p-value | [UB004](upstream-bugs/UB004-bad-rng-nan.md) |
| DC7 `:indep` | Zero or `0xff`, 4 KiB | Infinite combined statistic; NaN p-value | [UB004](upstream-bugs/UB004-bad-rng-nan.md#dc7-independence) |
| Gap-16:C | `arbee` seed 1, 2,816 KiB (2.75 MiB) | NaN rarity statistic and p-value | [UB006](upstream-bugs/UB006-gap16-rarity-nan.md) |
| BCFN_FF `:freq` | `0xff`, 4 KiB; zero, 8 KiB | NaN raw statistic and p-value | [UB004](upstream-bugs/UB004-bad-rng-nan.md#bad-input-empty-histograms-in-experimental-tests) |
| LimitedBigGapPrototype `LBGP:cross` | `0xff`, 64 KiB | NaN raw statistic and p-value; gap rows also fail from 256 KiB | [UB004](upstream-bugs/UB004-bad-rng-nan.md#bad-input-empty-histograms-in-experimental-tests) |
| CoupGap | Zero or `0xff`, 256 KiB | NaN G-test result; calibration aborts with `sample_to_index129: sample is NaN` | [UB004](upstream-bugs/UB004-bad-rng-nan.md#bad-input-empty-histograms-in-experimental-tests) |
| Coup32 `:mean` | Any of the four fixtures, 1 KiB; also empty | Raw NaN; `TYPE_UNKNOWN` supplies p-value 0.5 and suspicion 0 | [UB016](upstream-bugs/UB016-coup32-incomplete-mean.md) |
| SimpleClassifyWord `SCW` | Empty | NaN raw statistic and derived p-value | [UB015a](upstream-bugs/UB015a-empty-g-test.md) |

The first three are in the implemented core/Expanded scope. The other five are
compiled upstream experimental classes; these findings do not imply that the
normal core/Expanded batteries select them. `CoupGap` aborts before appending a
result, so counting NaNs only in returned result rows would miss it.

The source review covered all 36 implemented statistical test classes, shared
`math.cpp`, calibration/result conversion in `tests_core.cpp` and headers,
`non_uniform.cpp`, and CLI reporting. It indexed 273 preprocessed numerical call
sites, then checked surrounding arithmetic and guards; calls in constant-false
branches still need reachability analysis. Commented-out and `#if 0` code was
excluded. The actual probes link the unchanged official library. Diagnostic
copies under `.work/` added prints only to locate intermediate NaNs.

The retained [isolated driver](../test/upstream_nan.cpp) and
[manual audit runner](../test/audit_upstream_nan.py) construct one class per
process, preserve required negative-index history, and request results at powers
of two beginning at 1 KiB. Each class uses zero, `0xff`, a repeated `0..255` byte
ramp, and `arbee` seed 1; the initialization RNG is `arbee` seed 0. Separate
processes request empty results. The ordinary limit is 1 MiB; Birthday32 uses
8 MiB; GapUniversal1, Pat5, DistFreq4, the four Triple* variants, LPerm16, and
LPerm16A use 32 MiB. An alternating zero/all-ones 32-bit-word fixture exercises
Pat5's otherwise unreached pattern results at 1 MiB. Gap16 has the separate
2,816 KiB reproduction. This gives 182 isolated stream/empty cases, plus scalar
math and calibration probes. See [commands](testing.md#isolated-upstream-nan-audit).

All 182 cases finished without a timeout. Five processes intentionally exposed
upstream aborts: BCFN_FF on the ramp (gamma parameters out of range), FPMulti on
zero (gap product becomes zero), CoupGap on zero and `0xff` (NaN), and NearSeq3
on zero (eventual threshold exhaustion after earlier NaN rows). An abort is not
a successful finite result. The BCFN_FF gamma-range abort and FPMulti zero-product abort are tracked separately in [UB015d](upstream-bugs/UB015d-bcfn-ff-gamma-range.md) and [UB022](upstream-bugs/UB022-fpmulti-zero-gap-product.md). Both experimental classes are outside the implemented rewrite subset. Helper findings are in
[UB017](upstream-bugs/README.md#ub017),
[UB018](upstream-bugs/README.md#ub018), and
[UB019](upstream-bugs/UB019-brank-inverse-endpoint.md).

Coverage limits matter: this is a bounded source-led audit, not proof over every
byte stream, constructor configuration, length, compiler, or platform. The build
used Apple Clang 21.0.0, x86-64/Rosetta, `-O3`, without fast-math. Birthday64 did
not reach its reporting threshold of 200 complete 64 MiB buffers (12.5 GiB);
its fixed Poisson-table arithmetic was probed separately and produced no NaNs.
Unimplemented classes, disabled BCFN_MT, integer RNG algorithms, arbitrary
memory corruption, and exhaustive developer-tool workflows are outside the
runtime coverage. The audit itself changed no statistical behavior. The subsequent rewrite fix
is documented in [D012](departures-from-upstream.md#d012--bad-rng-results-preserve-tail-endpoints).

LimitedBigGapPrototype also calculates an unused normalization before its minimum-count return. No floating-point invalid flag was observed for its empty state in the optimized build; this is not an additional emitted NaN result. Scalar controls also confirmed invalid-domain NaNs for `math_factorial(-1)` and `math_chisquared_to_normal(0,0)`. `chi_squared_test` on an empty normalized histogram produces infinity, and tested uniformity helpers guard empty states. Those controls and NaN propagation are distinct from the issue-specific failures.
