# UB068 — gjishC zero rotation

**Status:** Confirmed inherited source defect and native Debug trap; fixed locally
in both result modes under [D028](../departures-from-upstream.md#d028--defined-remaining-built-in-generator-arithmetic).

Source: `.vendor/PractRand/src/RNGs/other/simple.cpp` ([source acquisition](../reference-source.md)).
The rotation expression can shift by an invalid count. The local remedy
uses a width-normalized rotation (or removes an identity rotation), preserving
the observed original sequence.

The bounded native Debug CLI sweep reproduced:

```sh
RNG_test 'gjishC' -seed 0 -tf 0 -tlmin 1KB -tlmax 4KB -tlmaxonly -a -singlethreaded
```

Diagnostic: `shift exponent 32 is too large for 32-bit type 'Uint32' (aka 'unsigned int')`. This is an actual accepted input path, not an invalid
state manufactured by a test. The initial sweep used Zig 0.17.1 on native ARM64
macOS (sweep case 266).

The local adapter defines the rotation for the exercised count while
retaining state walks, native widths, names and the original recurrence.
The unchanged original byte fixtures and fresh optimized-original outputs agree
with the actual local adapter under fatal UndefinedBehaviorSanitizer checks,
using whole and irregular fills. Names, widths and flags agree too.
This bounded evidence does not
establish that every possible state or other imported algorithm is defect-free.
Vendor files, fixture bytes and comparison rules remain unchanged.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
