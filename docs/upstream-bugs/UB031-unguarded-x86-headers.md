# UB031 — Unconditional x86 headers prevent native ARM tool builds

**Status:** Confirmed native ARM64 macOS compile failure in unchanged 0.96.
Other compiler/platform combinations have not been tested for this record.

`tools/dummy_rng.h` includes `<x86intrin.h>` whenever `__GNUC__` is defined,
without checking the target architecture. Clang defines that macro on ARM too.
On Apple M2 with Apple Clang 21, this command fails inside `ia32intrin.h` with
undeclared `__builtin_ia32_*` identifiers before producing a tool:

```sh
clang++ -std=c++11 -fsyntax-only -I.vendor/PractRand/include \
  .vendor/PractRand/tools/RNG_output.cpp
```

`src/platform_specifics.cpp` has the same unconditional include. The active dummy
algorithm itself needs no x86 instructions; the header's unused helpers bring
them in. The existing explicit reference builder targets x86-64 on macOS, which
avoids this failure. This is a build portability defect, not a demonstrated error
in seeded byte streams.

## Rewrite handling

The built-in generator adapter uses portable OS-entropy/identifier/block helpers
and the same active dummy algorithm/walk order. It compiles the other generator
sources unchanged and never edits the vendored release. Retained original dummy
vectors check the native adapter's output. The independent reference driver uses
the unchanged dummy header on x86, with an equivalent active algorithm for ARM
syntax checks; its retained capture used the original x86 header.

Public disclosure has not been searched. Local evidence from November 12, 2026
is retained.
