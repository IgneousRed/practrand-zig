# UB061 — multish4x16 product

**Status:** Confirmed inherited source defect and native Debug trap; fixed locally
in both result modes under [D028](../departures-from-upstream.md#d028--defined-remaining-built-in-generator-arithmetic).

Source: `.vendor/PractRand/src/RNGs/other/oddball.cpp` ([source acquisition](../reference-source.md)).
The 16-bit factors promote to signed `int`; the product can overflow before
assignment or argument conversion reduces it to 16 bits.

The bounded native Debug CLI sweep reproduced:

```sh
RNG_test 'multish4x16' -seed 0 -tf 0 -tlmin 1KB -tlmax 4KB -tlmaxonly -a -singlethreaded
```

Diagnostic: `signed integer overflow: 55742 * 38585 cannot be represented in type 'int'`. This is an actual accepted input path, not an invalid
state manufactured by a test. The initial sweep used Zig 0.17.1 on native ARM64
macOS (sweep case 434).

A local adapter computes the product using unsigned 32-bit operands, then
retains the original 16-bit reduction and recurrence. Every 16-bit product fits
that unsigned intermediate.
The unchanged original byte fixtures and fresh optimized-original outputs agree
with the actual local adapter under fatal UndefinedBehaviorSanitizer checks,
using whole and irregular fills. Names, widths and flags agree too.
This bounded evidence does not
establish that every possible state or other imported algorithm is defect-free.
Vendor files, fixture bytes and comparison rules remain unchanged.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
