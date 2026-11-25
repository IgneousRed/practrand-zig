# Independent FPF/64 verification

The accepted [D010](departures-from-upstream.md#d010--fpf64-checkpoint-independent-sampling-bug-fix)
correction keeps windows at byte offsets 0, 8, 16, … across input calls. The
unchanged original uses this alignment on its first call and switches phase on
later calls ([UB001](upstream-bugs/UB001-fpf64-checkpoints.md)). Neither this
verification nor the correction changes the nominal sample-count convention in
[UB011](upstream-bugs/UB011-fpf-nominal-sample-count.md).

## Ordinary checks

```sh
python3 -B tools/zig_run.py build test-fpf64 -Doptimize=ReleaseFast
```

This bounded target runs the two checks in [test/fpf64.zig](../test/fpf64.zig).
They also run as part of `test-unit` and the full `test` target. Ordinary tests
never run the original or regenerate a fixture.

1. A direct bit-window oracle independently enumerates exponent and significand
   bits for every aligned 64-bit window. It does not use the kernel's word,
   trailing-zero-count or mask extraction. All 851,968 histogram bins are
   compared exactly after calls of 1, 3, 17 and 235 KiB. Four 256 KiB patterns
   cover all zeros, all ones, mixed words with every trailing-zero count through
   64, and deterministic SplitMix64 bytes. The capped exponent and implicit zero
   beyond the last bit of a word are included.
2. Reference-mode scoring is compared with 14 retained original rows at 1, 8 and
   256 KiB. Each original case constructs a fresh `FPF(6,14,6)` and calls
   `test_blocks` exactly once, avoiding the upstream phase switch. The checks
   include exact row count, order, names and result kinds, plus raw/processed
   values, probability, suspicion and unnormalized weight. SHA-256 checks bind
   each independently generated input prefix and the retained driver source to
   the capture.

The original capture is x86-64; the rewrite check also runs on ARM64. Raw,
processed and suspicion values use the existing scalar comparator's maximum of
absolute `1e-6` and relative `1e-10` tolerance. Probabilities use absolute
`1e-10`; weights use absolute `1e-15`. Every captured value must be finite.
These tolerances belong to this new isolated control. Existing full-suite
fixtures, integrity checks, comparison rules and FPF/64 exclusions are unchanged.
Improved-mode arithmetic retains its separate numerical controls; it is not
required to reproduce the original's reference calculation here.

The existing whole-versus-split FPF test in `src/battery.zig` remains. It checks
batching and checkpoint invariance for all four strides, while the direct oracle
checks which FPF/64 windows were counted and the original capture checks scoring.

## Original capture provenance

[test/reference-results/fpf64.json](../test/reference-results/fpf64.json) retains
the original values and capture metadata: official version/archive URL and
checksum, complete source-file hashes, compiler and flags, executable/output
checksums, input hashes, and the driver checksum. The driver is
[test/reference_fpf64.cpp](../test/reference_fpf64.cpp), using only unchanged
original classes and deterministic input generation; it does not call the
rewrite. Two executions produced identical complete output before acceptance.

The capture used Apple Clang 21.0.0 with
`-O3 -std=c++11 -pthread -arch x86_64` under Rosetta on macOS, through the
[reference builder](../tools/build_reference.py). Source and linked executable
inputs were frozen by that builder. Capture intermediates are retained locally.

To inspect a fresh independent capture, build and run the driver into a fresh
destination under `.work/`:

```sh
python3 -B tools/build_reference.py --driver test/reference_fpf64.cpp \
  --output .work/fpf64-reproduction/reference-fpf64
.work/fpf64-reproduction/reference-fpf64 > .work/fpf64-reproduction/original.tsv
```

Each TSV row is `blocks`, `name`, original `type`, `raw`, `processed`, `p-value`,
`suspicion`, `weight`. This explicit operation does not replace or accept a new
fixture. Fixture changes require reviewing the capture and provenance; ordinary
tests preserve the retained reference.
