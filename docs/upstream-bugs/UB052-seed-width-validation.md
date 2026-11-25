# UB052 — Native seed CLI and expression factory enforce different widths

**Status:** Confirmed source/command inconsistency in original 0.96. Intended
CLI intent unresolved. The user explicitly chose native CLI compatibility after
reviewing the inconsistency. The rewrite now preserves the native conversion
and acceptance; the original expression factory's 16–128-bit range is unchanged.

Original `tools/RNG_test.cpp:1016-1019` parses the `-ttseed` suffix with `atoi`
and rejects a negative value. Zero requests autodetection. The CLI does not
enforce the 16-bit minimum described by its help before constructing
`FastSeeder128_MetaRNG`. The wrapper constructor at `tools/SeedingTester.h:249`
constructs the corresponding seed mask without a minimum-width rejection.

The same original wrapper's expression factory, at
`tools/SeedingTester.h:357-364`, explicitly rejects widths below 16 or above 128.
Thus the original native CLI and expression paths disagree about which widths
are permitted. Whether the native CLI intentionally supports additional widths
or omitted intended validation is not established.

Bounded reproductions against unchanged original 0.96:

```text
RNG_test sfc64 -ttseed8 -seed 0 -tf 0 -tlmin 1KB -tlmax 1KB -tlmaxonly -a -singlethreaded -skip_selftest
RNG_test sfc64 -ttseed15 -seed 0 -tf 0 -tlmin 1KB -tlmax 1KB -tlmaxonly -a -singlethreaded -skip_selftest
```

Both completed naturally with status zero, empty stderr, and
`length= 1 kilobyte (2^7 seeds)`. Width 16 also completed. Before the authorized
correction, the rewrite rejected 8 and 15 with status one and the 16–128-bit
diagnostic in both arithmetic modes. This was a narrower command
domain, not evidence of different seed bytes at a shared supported width.

The original was built with Apple Clang 21.0.0, `-O3 -std=c++11 -pthread
-arch x86_64`, under Rosetta. The rewrite probe used its native ReleaseFast
reference-compatible executable. Reports and stderr are retained locally;
see audit finding 5.
The initial pass did not exercise tiny spaces, widths above 128 or long runs.

## Follow-up boundary check

In response to the user's question about identical behavior, another original
CLI probe at width 7 completed the same bounded 1 KiB test. Width 1 did not
complete within a three-second limit and was terminated by the probe. Its
`evolve_seed`/`record_seed` source explains the stalled progress: both possible
seeds remain in recent history, a rejected candidate does not advance/evict that
history, and the mutation fallback can only revisit the same two seeds.
These captures are retained locally.

This does not justify the rewrite's 16-bit minimum at widths 7, 8 or 15. Their
original native-CLI acceptance can be reproduced; the minimum came from the
help/expression-factory range rather than a technical need to reject them.
Literal native behavior also includes the original's one-bit nontermination.
No width-above-128 output behavior was tested or claimed.

## Authorized compatibility restoration

The user subsequently instructed “match the original.” Native `-ttseed` suffixes
now use the same C `atoi` conversion, reject negative converted values, and pass
other widths to the unchanged `FastSeeder128_MetaRNG`. Zero still requests the
original metadata calculation. This retains native acceptance of small spaces
and their original stalls, rather than introducing a new minimum. The selected
width is retained as a native integer through target selection, including when
a later `-ttnormal` overrides an earlier target. Conversion outside the C `int`
range and shifts for widths above 128 have undefined upstream behavior; no
portable-result claim is made for those inputs.

The additional Gray walks retain their 16–128 bounds. The unchanged original
expression factory retains its distinct bounds as well. Existing byte fixtures
and comparison rules were preserved. Five new original CLI report cases,
captured twice independently, are retained in
[seed-width-reports.json](../../test/seed-width-reports.json); they cover widths
7, 8 and 15, SFC16/32/64 and zero/mixed replay seeds. Bounded tests check exact
reference-compatible displayed rows, checkpoints in both modes, native suffix
conversion, negative rejection and tiny-width initialization without generating
the stalled stream. See [seed testing](../seed-testing.md).

ReleaseFast `test-seed` passed six adapter tests and eight CLI tests. Debug built
and passed the same eight CLI tests; its broader adapter run passed five tests
and hit the unrelated unchanged `binarymult16` overflow in the ordinary-vector
test, recorded in [UB053](UB053-binarymult16-signed-overflow.md). Eleven suffix
and negative-value cases also matched unchanged original statuses, checkpoints
and displayed rows in both Debug and ReleaseFast (33 bounded CLI runs). Source
checks passed. The full suite was not rerun.

## Public disclosure search

Not searched in this audit. No novelty or non-disclosure claim is made.
