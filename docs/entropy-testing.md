# Entropy testing

`-ttep` selects PractRand 0.96's entropy-pooling test target. It exercises an
RNG's entropy-accumulation methods using the original `EntropyPool_MetaRNG` with
fixed 57-byte strings. Each string is reset into the target pool, added through
`add_entropy_N`, flushed, and sampled with `raw64()`. The resulting eight-byte
samples feed the ordinary core or Expanded battery. Standard folding treats
them as 64-bit output.

```sh
.work/install/bin/RNG_test arbee -ttep -seed 0 -tlmin 1KB -tlmax 1KB
```

The rewrite fixes the original wrapper's iterator-decrement crash
([UB007](upstream-bugs/UB007-entropy-pool-crash.md)) locally in
`src/builtin_rngs.cpp` without modifying `.vendor/PractRand/`; see
[D024](departures-from-upstream.md#d024--safe-entropy-pooling-history-insertion-bug-fix).
Untouched upstream 0.96 reference executables still retain UB007.

## Setup, replay and target selection

The selected RNG expression must advertise entropy accumulation. Stdin, files,
ordinary generators such as SFC64, and wrappers that do not advertise that
capability are rejected before input is consumed. The two original named pools
are `arbee` and `sha2_based_pool`; capability alone does not establish that a pool
passes the original setup checks.

As in original `RNG_test.cpp`, setup checks that resetting reproduces the first
output, repeating the same 64-bit entropy reproduces the first output, and
changing that entropy changes at least one of the first two outputs. The
64-bit entropy is drawn from HC256 initialized with the replay seed. Checks use
the original call sequence, including its buffer behavior. In the reproduced
cases, `sha2_based_pool` fails the third check in both the original and rewrite;
the rewrite reports this on stderr with status one. It does not bypass the check
or silently add a flush.

After setup, the original wrapper's HC256 is seeded with the same 128-bit
hexadecimal `-seed` to choose its starting string and subsequent mutations.
Omitting `-seed` selects and prints a random 32-bit replay seed, as for normal
built-in input. C8 auxiliary randomness remains independent.

The last `-ttnormal`, `-ttseed[BITS]`, or `-ttep` chooses the target.
`--seed-walk` is specific to seed testing and is rejected with `-ttep`.
`--reference-compatible` selects statistical arithmetic; it does not select a
different entropy wrapper. Serial/threaded execution and normal report layouts,
filtering, time/length limits and failure stopping remain available.

## Lengths and reports

Bare log2 lengths and `K/M/G/T/P` suffixes count entropy strings. Explicit
`KB/MB/GB/TB/PB` suffixes count the eight-byte output samples' total bytes.
For example, `-tlmax 10` and `-tlmax 1K` mean 1,024 strings / 8 KiB, while
`-tlmax 1KB` means 128 strings / 1 KiB. Option order does not change parsing.
Time suffixes and the original byte/time defaults retain their normal meaning.

Reports retain the byte quantity and label the parenthesized log2 count:
`8 kilobytes (2^10 entropy strings)`. This is the number of tested output samples,
not the total entropy bytes supplied to the pool or all trial mutations used by
the wrapper's history search.

The ordinary expression `EntropyPoolingTester(RNG,MIN,MAX)` remains available
without `-ttep`. It retains byte length/report units and does not perform the
native target's basic checks. Its factory still uses MIN for both bounds,
ignoring MAX ([UB003](upstream-bugs/UB003-entropy-wrapper-bounds.md)).
One-byte direct expressions are rejected before creating the child RNG in both
result modes: duplicate-seed rejection can cover the entire seed space, leaving
no acceptable next seed. The original accepts this configuration and can stall
indefinitely; a CLI time limit cannot interrupt its blocked generator call.
See [UB054](upstream-bugs/UB054-entropy-history-exhaustion.md) and
[D027](departures-from-upstream.md#d027--reject-one-byte-entropy-messages).
Because the factory still ignores MAX, any effective one-byte configuration is
rejected even when MAX requests a larger size. The native target uses 57-byte
strings and is unaffected by this rejection.

## Verification and reference provenance

The full/unit targets include `test/entropy_cli.py`; focused verification is:

```sh
python3 -B tools/zig_run.py build test-entropy -Doptimize=ReleaseFast
```

Three retained vectors in [entropy-vectors.json](../test/entropy-vectors.json)
come from [reference_entropy.cpp](../test/reference_entropy.cpp), linked against
unchanged official 0.96 under x86-64/Rosetta. The driver follows original CLI
setup and uses the unchanged wrapper. Each 1,027-byte case was captured twice
with identical bytes and metadata required. Seeds include zero, a nonzero low
word and a mixed 128-bit value. The fixture records the archive, driver and
executable checksums, compiler, architecture and build command. Tests compare
whole and irregular native adapter fills, including partial output words;
they never build the original or recapture expected values.

CLI checks cover string/byte units (including `0.125K` and `1K` strings),
additional checkpoints, option ordering, target overrides, invalid targets
without blocking on stdin, basic-check rejection, both batteries and arithmetic
policies, standard/extra folding, serial/threaded full-precision reports against
the direct wrapper expression, `arbee` `-ttep` through 32,768 strings
(`262,144` bytes, past `history_length = 16,384`), and direct
`EntropyPoolingTester(...)` runs for both `arbee` and `sha2_based_pool`.
The checks also reject one-byte configurations, including nested expressions
and the inherited MIN/MAX parsing, before an open stdin pipe can be read; a
two-byte control still runs. These checks cover both result policies.
Those checks verify the rewrite's fixed adapter; the three retained original
1,027-byte vectors independently check byte-exact agreement with non-crashing
upstream runs. Because untouched 0.96 still carries UB007, larger captures
against the untouched reference executable are not guaranteed to complete.

To reproduce a vector into disposable storage:

```sh
python3 -B tools/build_reference.py --driver test/reference_entropy.cpp \
  --output .work/entropy-reference/reference-entropy
.work/entropy-reference/reference-entropy arbee 0 0 1027 \
  > .work/entropy-reference/arbee-zero.bin
shasum -a 256 .work/entropy-reference/arbee-zero.bin
```

Arguments are expression, hexadecimal low/high replay seed words and requested
output bytes. A successful capture against untouched 0.96 is not guaranteed
because the original wrapper retains UB007. Existing fixtures remain
authoritative.
