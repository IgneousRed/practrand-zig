# UB050 — Seed-width autodetection adds 64 for low-word-only metadata

**Status:** Source-confirmed formula error; no affected current built-in factory
identified. Preserved for compatibility.

In `.vendor/PractRand/tools/RNG_test.cpp`, the `-ttseed` maximum-seed metadata
branch adds 64 both when the high word is nonzero and when only the low word is
nonzero. A maximum seed of `0xffffffff` with high word zero would select 96 bits
rather than 32. `vRNG::get_maximum_seed` describes the largest seed producing a
distinct initialized state. Current inspected factories inherit the default
metadata, so this is a latent source finding, not a reproduced built-in failure.

The port retains the calculation when width is omitted in any walk mode.
Explicit `-ttseedBITS` avoids it; balanced Gray rejects a resolved non-power-of-two
width. The original wrapper's random walk is unchanged.

Evidence: the two metadata branches in original `RNG_test.cpp`, and the metadata
contract in `include/PractRand/rng_basics.h`. The reference driver retains the
calculation; durable default-width SFC vectors cover its current normal path,
not the hypothetical low-word-only case.

Public disclosure status: not searched for this newly identified issue. No public
report or upstream behavior change is implied.
