# UB055 — fibmulmix16 multiplication overflows promoted signed int

**Status:** Confirmed inherited source defect; fixed locally in both result
modes under [D026](../departures-from-upstream.md#d026--defined-fibmulmix16-products-bug-fix).
Separate from [UB053](UB053-binarymult16-signed-overflow.md).

Original `src/RNGs/other/cbuf.cpp`, in both loops of `fibmulmix16::raw16`,
computes `Uint16 product = a * (b | 1)`. Both operands promote to signed int;
valid 16-bit factors can produce an unrepresentable signed product before the
16-bit assignment. The broad Debug adapter-vector test, after passing the
binarymult16 correction, trapped with operands 56,828 and 51,535 at line 691.

The retained pre-polish Debug executable independently reproduces the same
mechanism on a valid native CLI path:

```sh
RNG_test fibmulmix16 -seed 0 -tf 0 -tlmin 1KB -tlmax 4KB -tlmaxonly -a -singlethreaded
```

It aborts before a checkpoint. Complete commands, captures and the adapter test failure
are retained locally. ReleaseFast retained vectors are the optimized-output oracle,
not proof that the original expression is defined C++.

## Local remedy, November 22, 2026

The user accepted the existing shared correctness policy: a local `FibMulMix16`
adapter defines each product using unsigned 32-bit operands before reducing it
to 16 bits, in both normal and reference-compatible modes. It preserves the
seven-word buffer, position, state walk, lag accesses, seeding and recurrence.
The original two refill loops become one ordered loop with the same cyclic lag
index; the identity rotations on its two factors are omitted. The rotation of
the preceding word remains five bits. All 16-bit factors fit the exact unsigned
32-bit product. Previously defined products are identical; overflowing original
expressions do not have a portable C++ output.

An independent Python integer recurrence is compared with untouched optimized
original code and the actual adapter compiled at `-O0` with fatal UndefinedBehaviorSanitizer
checks. It exercises twelve random/boundary states at nine buffered positions,
8,192 words per case, checking output and final walked state. The existing
original byte fixtures remain unchanged and authoritative for normal seeded
whole/irregular reads. The investigation retained the independent integer-control
method and matching state/output observations.
Fresh native Debug CLI runs through 4 KiB complete with status zero and three
checkpoints in both result modes (`debug-cli.json`).

The broad Debug vector check gets past this generator and then reaches the
separate [UB056 garthy16 overflow](UB056-garthy16-signed-overflow.md), now fixed
in the broader pass. The later [UB070 Ranrot](UB070-ranrot-zero-rotation.md)
choice preserves the captured original stream with a warning and provides
separate fixed names. The Debug unit/check and CLI target now passes, including
all unchanged original generator vectors. Vendor sources, fixture bytes and
comparison rules remain unchanged.

The full CPU ReleaseFast suite also passed Zig/Python/CLI checks and all six
fresh 4 GiB SFC16/32/64 comparisons in both result modes. Retained inputs and
comparison rules were unchanged; run-local Zig caches were removed.

## Public disclosure search

Not searched during this polish. No novelty or non-disclosure claim is made.
