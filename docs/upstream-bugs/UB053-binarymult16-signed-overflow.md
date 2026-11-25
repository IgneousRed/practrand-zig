# UB053 — binarymult16 multiplication overflows promoted signed int

**Status:** Confirmed source defect in unchanged official 0.96. The rewrite now
defines the multiplication locally using an exact unsigned 32-bit product; see
[D025](../departures-from-upstream.md#d025--defined-binarymult16-product-bug-fix).
Vendored source and retained expected bytes remain unchanged.

Original `src/RNGs/other/oddball.cpp:71`, in `binarymult16::raw16`, evaluates
`b * (c | 1)` before assigning to its 16-bit unsigned state. Integer promotion
makes this a signed `int` multiplication on the supported targets. The observed
operands 53178 and 58383 produce a result outside that type's range. Assignment
back to an unsigned 16-bit field does not make the preceding overflow defined.

This was discovered while checking the separately authorized native seed-width
compatibility correction. The ReleaseFast generator/vector checks passed;
the Debug generator checks trapped in an existing retained output vector.
An independent, valid CLI reproduction confirmed reachability:

```text
RNG_test binarymult16 -seed 0 -tf 0 -tlmin 1KB -tlmax 1KB -tlmaxonly -a -singlethreaded
```

The current Debug executable terminated with SIGABRT before completing a
checkpoint and diagnosed `53178 * 58383` as signed overflow. Current ReleaseFast
and unchanged original 0.96, built with Apple Clang 21 `-O3 -arch x86_64` and run
under Rosetta, each completed one checkpoint with status zero and empty stderr
(original adds `-skip_selftest`). Successful optimized execution does not
establish defined C++ behavior. The rewrite's Debug trap alone does not prove
that optimized outputs differ between compilers or platforms.

Commands, statuses, stderr and complete per-executable captures are retained
locally. The unchanged original executable's provenance is also retained in
`test/seed-width-reports.json`; Zig was 0.17.1 on PATH. Vendored code, existing
byte fixtures and comparison rules were not changed.

**Impact before the local remedy:** Debug execution of this generator, and the
broad Debug generator check that includes it, aborted. The focused seed CLI
checks passed in Debug and ReleaseFast; the failing case tested ordinary RNG
output, not the new seed-width path. The remedy below addresses this generator;
the separate UB055 overflow was later fixed, and
[UB056](UB056-garthy16-signed-overflow.md) was fixed in the broader pass. The
remaining Debug boundary is [UB070](UB070-ranrot-zero-rotation.md).

## Local remedy and verification

The subsequent overnight polish explicitly authorized a remedy if its semantics
were unambiguous and independently verified. A local `BinaryMult16` adapter
retains the original four-word state, walk order, name and recurrence, but
computes `Uint32(b) * (Uint32(c) | 1)` before assignment to `Uint16`.
The maximum product, 65,535 squared, fits unsigned 32 bits. Assignment reduces
it modulo 65,536. Every previously defined signed product has the same result;
for overflowing products this supplies a definition rather than claiming that
undefined C++ behavior has a universal output.

An independent Python arbitrary-precision recurrence agreed on 98,304 words
across eight seeded states and four boundary states, including the original
failing operands, with both untouched original Clang `-O3` code and the local
adapter compiled at `-O0` with fatal UndefinedBehaviorSanitizer checks.
The oracle source, complete output and sanitizer stderr are retained locally.
Existing original byte vectors also passed the binarymult16 cases in Debug
before the broad test reached the separate [UB055](UB055-fibmulmix16-signed-overflow.md)
overflow. The broad Debug suite is therefore still not a passing configuration.
The source fix does not affect the SFC reference generators or numerical policy.
The final ReleaseFast full suite on Zig 0.17.1 passed 41 build steps, 162
Zig/GPU tests, 38 Python checks, all bounded CLI groups and six fresh 4 GiB
SFC16/32/64 reference/improved comparisons. Metal and Vulkan libraries compiled
with fatal warnings, with 77 native Metal hardware checks. Full evidence is
retained locally.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
