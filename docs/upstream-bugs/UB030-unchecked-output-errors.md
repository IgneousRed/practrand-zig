# UB030 — Failed report writes can still be treated as success

**Status:** Confirmed unchecked upstream output boundary by source review;
deterministic runtime probes reproduce the same mechanism in the rewrite.
No upstream byte-stream run with failed stdout was added.

Original 0.96's `RNG_test.cpp` (`.vendor/PractRand/tools/RNG_test.cpp`) ([source acquisition](../reference-source.md))
ignores the results of its report `printf` calls and final `fflush(stdout)`.
It can then stop on a statistical failure with `exit(0)`, or continue normally,
even when the output was lost. C stream errors do not by themselves change a
program's successful exit status. Help/version output has the same unchecked
write pattern.

The rewrite previously ignored these results too. An isolated reporter probe
with one `.good_p` result, weight 1, one 1 KiB block and zero elapsed seconds
returned its ordinary decision with status 0 when stdout was a read-only
descriptor. Both p=0.5 (ordinary) and p=0 (statistical failure) reproduced this,
with buffered and unbuffered stdout. No battery was constructed. Separate
help/version probes also returned 0 with unwritable stdout.

An actual-libc unbuffered probe on that descriptor returned `printf=-1`,
`fflush=0`, and `ferror=1`. Checking only the final flush is therefore insufficient:
the sticky stream error must be checked as well. A writable descriptor preserves
the existing PASS/FAIL decision. Invalid-weight and invalid-probability probes
retain their original errors even if their diagnostics cannot be written.

The rewrite now checks stdout at completed checkpoints and successful CLI
completion; see [D016](../departures-from-upstream.md#d016--stdout-failures-are-errors).
The fixed 16-case reporter matrix covers both buffering modes, writable/read-only
descriptors and ordinary/failing/invalid-weight/invalid-probability results.

Public disclosure was not searched for this record; earlier tracker searches
do not establish its disclosure status.
