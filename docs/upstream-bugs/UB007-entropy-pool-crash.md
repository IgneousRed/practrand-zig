# UB007 — Entropy-pool target can crash in the reference build

**Status:** Confirmed upstream source defect; reproduced in the untouched x86-64
reference build and previously in the native ARM64 rewrite. Fixed in the rewrite
adapter (`src/builtin_rngs.cpp`) for both `-ttep` and `EntropyPoolingTester(...)`
under [D024](../departures-from-upstream.md#d024--safe-entropy-pooling-history-insertion-bug-fix),
with `.vendor/PractRand/` kept byte-for-byte unchanged. See
[entropy testing](../entropy-testing.md).

`RNG_test arbee -seed 0 -tf 0 -tlmin 10 -tlmax 10 -tlmaxonly -skip_selftest -ttep`
terminated with signal 11 before emitting a checkpoint. The equivalent
`sha2_based_pool` probe returned 0 with a checkpoint. This does not establish
that all entropy pools or platforms crash.
Evidence: reference exit-status probes.

## Input-factory follow-up, November 21, 2026

The maintained original byte probe now registers all tester input factories.
An x86-64/Rosetta build against unchanged 0.96 reproduced signal 11 for
`EntropyPoolingTester(arbee,57,57)` and
`EntropyPoolingTester(sha2_based_pool,57,57)` at 4,099 requested bytes, after
printing the correct wrapper name and before completing output. Smaller
8-byte-string cases sometimes completed; one `(arbee,8,8)` capture also crashed.
This extends the observed scope to the direct factory interface. It does not
establish a cause or deterministic crashing boundary. The driver fills whole
1 KiB blocks, including when fewer output bytes are requested.

Reproduction (from the project root):

```sh
python3 -B tools/build_reference.py --driver test/reference_rngs.cpp \
  --output .work/input-reference/reference-rngs
.work/input-reference/reference-rngs 'EntropyPoolingTester(arbee,57,57)' 0 0 4099
```

No compatibility correction was authorized. The production factory links the
same wrapper. The durable input fixture retains construction/name/native-width
cases for entropy wrappers, with no entropy-output equivalence claim; other
input expressions have retained byte vectors. Crash risk remains documented in
[input usage](../builtin-rngs.md#stream-inputs-and-special-wrappers) and
[D023](../departures-from-upstream.md#d023--stream-input-lifecycle-and-errors).

## Native target follow-up, November 21, 2026

The `-ttep` workflow now performs the original three basic checks and uses the
unchanged 57-byte wrapper. Three 1,027-byte Arbee cases from the independent
original-library driver completed twice with identical bytes and metadata;
these are retained in `test/entropy-vectors.json`. Native whole/irregular fills
are compared against those bounded cases. This does not resolve the crash.

Fresh unchanged x86-64 CLI probes with Arbee seed zero completed at 1 KiB, but
two core probes through 4 KiB crashed with signal 11. Of two Expanded probes
through 4 KiB, one completed and one crashed. A seed-one core 1 KiB probe also
crashed. No deterministic crashing boundary or cause is established.

The native ARM64 ReleaseFast target also reproduced signal 11 with Arbee seed
zero at a requested `-tlmin 1K -tlmax 1K` (1,024 strings / 8 KiB output). The
initial focused integration run failed on this case. A second focused run,
bounded at 4 KiB and using `0.125K` for suffix scaling, passed. The full suite
then failed at the entropy CLI's 4 KiB case after reporting 1 KiB and 2 KiB.
The new checks retain that failure; neither smaller prefixes nor a single
focused pass establish reliable completion. The full suite did not reach its
SFC fixture comparisons because this prerequisite failed.

After the simplification/bug-hunt pass consolidated the entropy probe with the
existing input probe, a fresh full ReleaseFast run passed all checks and all six
4 GiB SFC comparisons. The wrapper and CLI cases were unchanged. That passing
run does not invalidate the earlier failures or establish a safe input boundary.

Fresh `sha2_based_pool -ttep` probes at seeds zero, one and `123456789abcdef`
were rejected by the original third basic check before wrapper output; the
rewrite preserves that check and reports failure with status one. These setup
rejections do not establish that UB007 is fixed or absent for SHA2 wrapper
expressions. See [entropy verification](../entropy-testing.md#verification-and-reference-provenance).

## Root-cause diagnosis, November 21, 2026

In original `tools/SeedingTester.h`, `EntropyPool_MetaRNG::evolve_seed()`
computes `sitr = unordered_history.equal_range(hash)` and inserts the new hash
with a decremented iterator hint:

```cpp
if (sitr.first == unordered_history.end()) it = unordered_history.insert(hash);
else it = unordered_history.insert(--sitr.first, hash);
```

`sitr.first` is `lower_bound(hash)`. The guard checks `unordered_history.end()`,
but does not check `unordered_history.begin()`. Whenever `unordered_history` is
non-empty and `hash <= *unordered_history.begin()`, `--sitr.first` decrements
`begin()`, which is C++ undefined behavior. Both `-ttep` and direct
`EntropyPoolingTester(...)` expressions execute this code path for any pool.

Under `libc++` on 64-bit macOS (both ARM64 and x86-64/Rosetta),
`unordered_history` (`std::multiset<Uint64>`) is 24 bytes
(`__begin_node_`, an 8-byte `__end_node_` containing only `__left_`, and
`__size_`), immediately followed at +24 bytes (`offsetof` 8656 → 8680) by
`history` (`std::deque<std::pair<iterator, Transform>>`), whose first word is
its heap map pointer `P` (`history.__map_.__first_`). Decrementing `begin()` in
`std::__tree_prev_iter` walks up left-child links through the root onto
`&__end_node_` and reads its nonexistent `__parent_` field 16 bytes past
`&__end_node_`, aliasing `P`. `unordered_history.insert(hint, hash)` then enters
`__tree::__find_leaf` and reads `*hint` at `P + 32`
(`__tree_node<Uint64>::__value_`), 24 bytes past the initial 8-byte map buffer.

This explains why failures are intermittent and depend on heap layout, seed and
length:

- If `P + 32` is mapped and its value compares `< hash` (for example, zeroed
  heap memory), `__find_leaf` falls back to `__find_leaf_low` and searches from
  the root, so the run survives with unchanged output.
- If `P + 32` is unmapped or compares `>= hash` (more likely as new minimum
  hashes shrink and when prior heap activity leaves non-zero bytes after `P`),
  `__find_leaf` decrements `P` as a tree node, chases `P[0]` into a deque block
  and dereferences an integer `Transform` value as a node pointer (`SIGSEGV`),
  or links the new RB-tree node into `history.__map_`.

Verification:

- Compiling `src/builtin_rngs.cpp` and `test/input_probe.cpp` with Apple Clang
  `-fsanitize=address,undefined` immediately reported
  `AddressSanitizer: heap-buffer-overflow` (`READ of size 8` at `P + 32`, 24
  bytes after the 8-byte `std::deque` map allocation) in `__tree::__find_leaf`
  called from `EntropyPool_MetaRNG::evolve_seed()` (`SeedingTester.h:548`) for
  `arbee -ttep` seed `0` (at 64 bytes), `EntropyPoolingTester(arbee,57,57)`, and
  `EntropyPoolingTester(sha2_based_pool,57,57)`.
- An uninstrumented `-O2` build of the same probe reproduced signal 11 on
  `arbee` seed `0` at 8,192 bytes.
- A disposable `.work/` test guarding `sitr.first == unordered_history.begin()`
  passed ASan and UBSan through 262,144 bytes (32,768 strings, over twice
  `history_length = 16384`) for `arbee` and for
  `EntropyPoolingTester(sha2_based_pool,57,57)`, while matching the SHA-256
  digests of all three retained vectors in `test/entropy-vectors.json`. No
  production or vendor files were modified for this diagnosis.

## Rewrite fix, November 21, 2026

With `.vendor/PractRand/` kept unchanged, `src/builtin_rngs.cpp` now wraps
`EntropyPool_MetaRNG` in a local subclass whose `raw64()` inserts into
`unordered_history` with C++11's `unordered_history.insert(sitr.first, hash)`
(no decrement of `begin()`). Both native `-ttep` and the `EntropyPoolingTester`
expression factory construct this subclass, while retaining
[UB003](UB003-entropy-wrapper-bounds.md) and `sha2_based_pool`'s original basic
check 3 behavior; see
[D024](../departures-from-upstream.md#d024--safe-entropy-pooling-history-insertion-bug-fix).
The historical failure evidence above remains valid for untouched PractRand 0.96.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `-ttep, arbee, entropy-pool crash, signal 11`. See [search scope](README.md#search-scope) for coverage and limits.
