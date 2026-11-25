# Seed testing

`-ttseed` repeatedly calls the selected RNG's original `seed(low64, high64)`
and takes one `raw64()` result after its normal initialization/warmup. The
eight-byte samples are concatenated and tested by the ordinary core or Expanded
battery. Standard folding treats the stream as 64-bit, including for 16- or 32-bit
targets. This tests seeding together with initial output quality.

```sh
# Original PractRand 0.96 walk is the default.
.work/install/bin/RNG_test sfc64 -ttseed64 -seed 0 -tlmin 1K -tlmax 1M
.work/install/bin/RNG_test sfc64 -ttseed64 --seed-walk gray -seed 0 -tlmax 1M
.work/install/bin/RNG_test sfc64 -ttseed64 --seed-walk balanced-gray -seed 0 -tlmax 1M
```

`-ttnormal` selects ordinary output testing. `--seed-walk` requires a seeding
target. Input that cannot be reseeded is rejected. Built-in RNG expressions work.
For the separate `-ttep` target, see [entropy testing](entropy-testing.md).

## Width, lengths and replay

The original walk's `-ttseedBITS` follows the original native CLI: `atoi` parses
the suffix, and only negative values are rejected. An omitted suffix, zero or
a suffix with no initial number requests autodetection; leading whitespace or
`+` and trailing nonnumeric text follow that same conversion. Without a width,
`-ttseed` follows the original CLI's maximum-seed metadata calculation, defaulting
to 128 with a warning when metadata is unavailable. Its low-word-only metadata
error is preserved; see [UB050](upstream-bugs/UB050-seed-width-autodetection.md).
Prefer an explicit width within 16–128 for normal use. Native acceptance below
16 is preserved, including the original recent-history stall in tiny seed
spaces (a one-bit walk cannot progress through a 1 KiB checkpoint). Widths above
128 enter undefined shifts in the unchanged original wrapper; accepting such
commands does not establish portable results. See
[UB052](upstream-bugs/UB052-seed-width-validation.md). The original expression
factory `SeedingTester(RNG,BITS)` retains its separate 16–128 bounds.

The additional Gray walks require 16–128 bits. Balanced Gray supports 16, 32,
64 and 128 bits; other resolved widths fail with a diagnostic.

Bare log2 lengths and `K/M/G/T/P` suffixes count seeds in seeding mode. Explicit
`KB/MB/GB/TB/PB` suffixes count output bytes. Thus `-tlmax 10` and `-tlmax 1K`
mean 1,024 seeds / 8 KiB, while `-tlmax 1KB` means 128 seeds / 1 KiB. Parsing is
independent of option order. Time suffixes keep their ordinary meaning. Defaults
remain the original byte/time defaults. Reports retain upstream's byte-quantity
prefix and show seed counts in parentheses: `8 kilobytes (2^10 seeds)`.

`-seed` uses the normal hexadecimal convention. In original mode it initializes
the wrapper's HC256, which chooses the initial target seed and later changes.
In deterministic modes it is an XOR offset, truncated to the chosen width;
zero starts at target seed zero. Omitted seeds are chosen and printed as for
normal built-in input. C8 auxiliary randomness remains independent.

## Walks and stopping

1. **Original:** unchanged `FastSeeder128_MetaRNG` from PractRand 0.96. HC256
   proposes bit flips; a 16-bit hash table avoids the last 64 accepted seed hashes.
   If all one-bit proposals are rejected it permits larger mutations. This walk
   is not exhaustive and does not stop after a seed-space cycle.
2. **Gray:** reflected binary Gray code `i ^ (i >> 1)`, translated by the XOR
   offset. Every seed appears once; neighbors differ by one bit. Low bits change
   much more frequently than high bits.
3. **Balanced Gray:** recursive two-half traversal in
   [seed_testing.zig](../src/seed_testing.zig). Every seed appears once and every
   transition, including closure, changes exactly one bit. Full-cycle flip counts
   are within 14% of the mean for supported widths. This is approximate balance,
   not exact total balance or a proven bound on every short window.

Deterministic modes stop after one exhaustive pass, or earlier under ordinary
length/time/failure stopping. A 16-bit pass contains 65,536 seeds / 512 KiB.
The final checkpoint is reported even if the requested maximum is larger.
Prefetch is bounded by the pass. `--reference-compatible` chooses statistical
arithmetic; it does not change the selected walk.

### Balanced construction

The 4-bit base words are
`0,1,3,7,5,4,12,14,6,2,10,11,15,13,9,8`, with four flips per bit.
For two half-cycles of length L, visit rank pairs `(k,k-2p)` and `(k+1,k-2p)`
modulo L, for `k=0..L-1` and `p=0..L/2-1`. Their difference recovers `2p` or
`2p+1`; the first rank then recovers k, proving uniqueness recursively.
Each transition moves one half by one forward/backward cyclic step.

For child edge counts C, and counts E/O on even/odd child edges, parent counts
are `(L/2)*C` in the lower half and `(L/2)*C + E - O` in the upper half.
Parent even edges are all lower-half transitions; odd edges are all upper-half
transitions. This recurrence through 128 bits gives a worst relative count
deviation below 14%. Short-prefix distribution is checked separately.

## Verification and reference provenance

Unit/full targets check exhaustive small cycles, deterministic exhaustion,
one-bit transitions, short-prefix flip counts, whole/irregular adapter fills,
and bounded CLI cases for each mode and arithmetic policy, length units, option
order, invalid targets and final-cycle reporting.

Five independent original CLI captures in
[seed-width-reports.json](../test/seed-width-reports.json) cover widths 7, 8 and
15, SFC16/32/64, zero and mixed 128-bit replay seeds. Each case was captured
twice from unchanged 0.96 with identical results. Bounded checks require exact
displayed statistical rows in reference-compatible mode and successful
checkpoints in both result modes. They also cover native suffix parsing, negative
width rejection, tiny-width initialization without generating a stalled stream,
the separate expression-factory bounds and unchanged Gray restrictions.
Run the generator/seeding checks alone with
`python3 -B tools/zig_run.py build test-seed -Doptimize=ReleaseFast`.

The 71 retained vectors in [seed-vectors.json](../test/seed-vectors.json) come
from [reference_seeding.cpp](../test/reference_seeding.cpp), linked to unchanged
official 0.96 under x86-64/Rosetta. Each 4,099-byte case was captured twice and
required identical output. Coverage includes SFC16/32/64, zero and mixed replay
seeds, explicit widths, autodetection, and all modes. Original uses the upstream
wrapper. Deterministic cases compute seeds directly by rank and use the original
target's seed/output methods; balanced rank-to-word generation is independent of
the production incremental edge selector. Driver source, checksums, build command
and compiler identity are retained. Tests never rebuild or recapture the reference.

To reproduce one vector into disposable storage:

```sh
python3 -B tools/build_reference.py --driver test/reference_seeding.cpp \
  --output .work/seed-reference/reference-seeding
.work/seed-reference/reference-seeding sfc64 original 64 0 0 4099 \
  > .work/seed-reference/sfc64-original.bin
shasum -a 256 .work/seed-reference/sfc64-original.bin
```

Arguments: expression, mode, width (zero for autodetection), hexadecimal low/high
seed words, and output bytes. Existing fixtures remain authoritative.
