# UB056 — garthy16 multiplication overflows promoted signed int

**Status:** Confirmed inherited source defect and native Debug trap; now fixed
locally in both result modes under
[D028](../departures-from-upstream.md#d028--defined-remaining-built-in-generator-arithmetic).
Separate from the repaired UB053 and UB055 products.

Original `src/RNGs/other/oddball.cpp:46`, in `garthy16::raw16`, computes
`Uint16 temp = value * scale`. Both 16-bit factors promote to signed `int`;
valid factors can overflow before the 16-bit assignment. Assignment does not
make that intermediate product defined.

After the UB055 correction, the broad Debug original-byte-vector check passed
that generator and trapped here with operands 38,277 and 58,385. A fresh valid
native CLI reproduction independently aborts before its first checkpoint in
both normal and reference-compatible modes:

```sh
RNG_test garthy16 -seed 0 -tf 0 -tlmin 1KB -tlmax 4KB -tlmaxonly -a -singlethreaded
```

Both runs terminated with SIGABRT and the same signed-overflow diagnostic.
The diagnostic was captured with Zig 0.17.1 on native ARM64 macOS.
Optimized fixture agreement does not establish defined C++ behavior. This
record does not claim a cross-platform output mismatch or a complete arithmetic
audit. Vendor sources and expected byte fixtures remain unchanged.

## Local remedy, November 22, 2026

The user authorized the broader arithmetic cleanup. A local `Garthy16` adapter
computes `Uint32(value) * Uint32(scale)` before the original 16-bit reduction.
Its counter/scale wrapping, zero-counter branch, seven-bit rotation, state walk
and name are preserved. The maximum product fits the unsigned intermediate.

Both retained seeded cases match fresh optimized-original output and the actual
adapter under fatal UndefinedBehaviorSanitizer, using whole and irregular reads;
flags, native width and name also agree. Upstream sources and expected
bytes are unchanged. The separate Ranrot compatibility choice is now resolved
under [UB070](UB070-ranrot-zero-rotation.md): original names warn and preserve
the captured stream, while `_fixed` names implement the intended recurrence.
The Debug unit/check and CLI target passes with those choices.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
