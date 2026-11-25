# UB051 — Decimal length accumulation can lose one test block

**Status:** Confirmed original CLI rounding behavior on x86-64; exact source
mechanism identified. The user requested preservation after the audit.
The rewrite now uses the original digit-by-digit calculation in both result
modes, including this rounding behavior. Malformed and overflowing requests
retain the documented rewrite rejection.

In original `tools/RNG_test.cpp`, `interpret_length` (lines 517–538) accumulates
decimal fractional digits with repeated `value += digit * sig` and `sig *= 0.1`.
The resulting byte quantity is truncated to complete 1 KiB blocks when inserted
into the checkpoint map (lines 1091–1094). A decimal that denotes an exact
integer number of blocks can accumulate to slightly less than that integer.

Against unchanged official 0.96, these valid commands completed with status
zero and empty stderr:

```text
RNG_test sfc64 -seed 0 -tf 0 -tlmin 1.0029296875M -tlmax 1.0029296875M -tlmaxonly -a -singlethreaded -skip_selftest
RNG_test sfc64 -seed 0 -tf 0 -tlmin 1.00390625M -tlmax 1.00390625M -tlmaxonly -a -singlethreaded -skip_selftest
```

The first tested 1026 KiB instead of the represented 1027 KiB; the second tested
1027 KiB instead of 1028 KiB. Original reports respectively printed
`1.002 megabytes (2^20.003 bytes)` and
`1.003 megabytes (2^20.004 bytes)`. The integer-unit control `1027K` selected
1027 KiB as expected.

At the audited commit, the rewrite used `std.fmt.parseFloat` before unit scaling
and complete-block conversion. It selected the exact 1027/1028 KiB quantities
in both cases with `--reference-compatible`. This established a compatibility
difference, not an incorrect mathematical interpretation. The subsequent
compatibility decision restores original conversion in `src/main.zig` for
minimum, maximum and additional checkpoints. A focused test retains the two
original CLI expectations, explicit-byte/count unit handling and invalid syntax.

The reproduction used Apple Clang 21.0.0, `-O3 -std=c++11 -pthread -arch x86_64`,
under Rosetta on macOS. The source remains the unchanged official release
recorded in [vendor provenance](../reference-source.md). See the
focused audit. Initial captures
predate the restoration. Follow-up captures verify the restored parser against
the unchanged original function and CLI; no original fixtures or comparison
rules were changed. Commands and captures are retained locally.

The extracted unchanged original function also gives 8215 blocks for
`1.0029296875M` in a seed/string target, 1026 blocks for the explicit-byte
`1.0029296875MB`, and `3.0000000000000004` seconds for `0.05m`. These controls
are retained in the focused parser test. The original function excerpt, driver,
output and hashes are retained locally.

Follow-up verification passed the focused ReleaseFast parser test, Debug and
ReleaseFast builds, and source checks. Eighteen successful CLI runs over six
cases compared the original with both rewrite result modes, matching all
displayed statistical rows and checkpoint lengths. They covered both reported
fractional boundaries, the integer control, and minimum/maximum/additional
checkpoint scheduling. Three Debug boundary/control runs also passed. Four
invalid-syntax/overflow cases rejected before reading an open empty stdin pipe.
This was targeted validation; no full-suite pass is claimed.

## Public disclosure search

Not searched in this audit. No claim is made that the issue is new or undisclosed.
