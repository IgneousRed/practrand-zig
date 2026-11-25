# UB070 — Full-width Ranrot zero rotations invalidate the refill

**Status:** Confirmed inherited invalid shifts. Accepted local remedy under
[D029](../departures-from-upstream.md#d029--explicit-legacy-and-fixed-ranrot-generators):
original names warn and retain the captured repeating stream; new `_fixed`
names evaluate the intended changing recurrence. Both result modes share this
explicit generator choice. Vendor and original fixtures remain unchanged.

`_RanrotVariant` in `.vendor/PractRand/tools/Candidate_RNGs.h` instantiates
`ranrot_var32` and `ranrot_var64` with SHIFT1=SHIFT2=0. Its rotation helper
then shifts a full-width word right by 32 or 64, which is undefined C++.
Rotating by zero should leave the word unchanged, but the helper evaluates
the invalid shift anyway. A Debug build detects it and aborts. Optimized code
has no defined C++ outcome for that expression; the frozen reference's repeated
output is an observed compiler result, not a portable definition of Ranrot.
Both native Debug seed cases abort through the real CLI with that diagnostic.
The bounded CLI sweep confirmed both seed cases.

An isolated local remedy replaced those two zero rotations with identity while
preserving the seeded 45-word buffer, counters, walk and reverse output order.
It removed the trap but failed the unchanged original-byte fixture. At seed zero,
the original and local seed states were identical; the output differed at the
first refill. This is independent of statistical arithmetic or report rounding.

The untouched optimized original exactly repeats its 45 seeded words through
all 4,099 captured bytes in each of the four retained seeded cases. A defined
recurrence instead updates the buffer. The intended refill computes new words
from old buffer entries, rotations, addition and counters; the saved original
captures instead cycle through the seeded buffer. These bounded observations do
not establish identical behavior with other compilers or all possible lengths.
The original-output hashes match the retained fixture:

1. `ranrot_var32`: `a9691fcb3c8cf961f4586d09a68f444619d5f81f9be8326c47c44a1ea2987d50`.
2. `ranrot_var64`: `28ac23fbbf16a07b6fb2faadf97dfbfd15e75c6a2520ddd469d56f5c7b8c7b66`.

Independent state probes and the rejected remedy established the four original
hashes and exact periodic repetition. The unchanged generator fixtures retain
those original streams; the maintained reproduction below captures state. The proposed Ranrot remedy was removed from the
implementation and factory map. Other local arithmetic remedies continue to
match the original fixtures. No comparison exception was added.

## Accepted remedy

The user selected separate explicit names on November 22, 2026. The legacy
adapters keep the seeded buffer unchanged, advance the original counters at each
refill and retain reverse read order. This defines the frozen observed stream
without evaluating an invalid shift. A successful CLI initialization warns that
the original 45-word buffer repeats and recommends the corresponding `_fixed`
name. Nested occurrences are detected during expression construction.

`ranrot_var32_fixed` and `ranrot_var64_fixed` use the original recurrence with
zero rotations as identity; the buffer changes at refill. Seed mapping, state
walk, counter carry timing and output order remain the same. Neither statistical
result policy changes which stream an explicit name selects.

Separate retained `test/ranrot-fixed.json` expectations use original seed states
captured by `test/reference_ranrot_state.cpp`, which never executes the original
refill, and arbitrary-precision arithmetic in `tools/capture_ranrot_fixed.py`.
Tests check both widths and seeds through 65,539 bytes with whole and irregular
reads. The original 732 byte-vector cases are still checked without exceptions.
CLI checks cover both result policies, nested/repeated selections, the absence
of a legacy warning for fixed names and composition with metadata warnings.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
