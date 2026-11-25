# UB054 — One-byte entropy-wrapper history can exhaust the message space

**Status:** Confirmed inherited stall. The rewrite rejects effective one-byte
messages under [D027](../departures-from-upstream.md#d027--reject-one-byte-entropy-messages)
in both result modes. Separate from the repaired
[UB007](UB007-entropy-pool-crash.md) iterator defect.

The original factory accepts `EntropyPoolingTester(arbee,1,1)`. A one-byte message has
only 256 possible values. `EntropyPool_MetaRNG` remembers up to 16,384 accepted
messages, rejects remembered candidates, and evicts history only after accepting
a transition. It cannot continue indefinitely in this smaller message space;
it may get stuck earlier if every reachable candidate is already remembered.
The local safe-insertion adapter preserves that transition/history policy.

A bounded valid CLI reproduction on the retained Debug executable printed the
1 KiB checkpoint and did not complete within five seconds:

```sh
RNG_test 'EntropyPoolingTester(arbee,1,1)' -seed 0 -tf 0 \
  -tlmin 1KB -tlmax 4KB -tlmaxonly -a -singlethreaded
```

The identical `(arbee,8,8)` control completed with status zero. Commands,
statuses, time limits and captures are retained locally. The executable was built from
the current adapter before the unrelated binarymult16 remedy. A separate
read-only reviewer independently reproduced the one-byte stall. No timeout is
built into the generator, and a tester time limit cannot interrupt a blocked
single generator call.

## Rejection, November 22, 2026

The user accepted setup rejection and requested this simple explanation:
duplicate-seed rejection can cover the entire seed space, leaving no acceptable
next seed. The original has the same finite-history mechanism; accepting the
configuration does not give it a way to escape the stall.

The rewrite rejects effective one-byte messages before creating the child RNG,
including nested expressions, with stderr/status one in both result modes.
The original MIN/MAX conversion remains unchanged (UB003): MIN supplies both
bounds, so MIN=1 with a larger MAX is rejected too. This also rejects short
prefixes that previously completed; the history/walk is not redesigned.
The native `-ttep` target still uses 57-byte strings. The separately chosen native
tiny seed-width compatibility behavior remains unchanged.

Eight entropy CLI tests pass in Debug, including both policies, nested wrappers,
inherited numeric parsing, rejection before reading an open stdin pipe, and a
two-byte control through 4 KiB. Existing eight-byte/57-byte cases remain active.
No original fixture or upstream source was changed.

The full CPU ReleaseFast suite also passed Zig/Python/CLI checks and all six
fresh 4 GiB SFC16/32/64 comparisons in both result modes. Retained inputs and
comparison rules were unchanged; run-local Zig caches were removed.

## Public disclosure search

Not searched during this polish. No novelty or non-disclosure claim is made.
