# UB014 — Pat5 omits tail centers on every input call

**Status:** Confirmed coverage/batching behavior; whether this is an unintended
defect is unresolved. The port preserves the per-call omissions; execution mode
can select different call boundaries.

`Pat5::test_blocks` stops five words before the end of each input batch. On later
calls it starts at center 0 rather than replaying those negative-index centers,
so the omitted five centers are not reconsidered with new lookahead. Results
can consequently depend on input batching. The nominal opportunity count only
subtracts the initial/final pattern margins, rather than per-call omissions,
although non-matches are disabled in the active implementation.

Evidence: original `src/tests_other.cpp`, `Pat5::test_blocks` and `get_results`.
The planted-pattern fixture in Expanded validation
includes boundary centers; the port retains the source's omitted tail and
negative history behavior rather than silently testing additional centers.

## CLI batching follow-up, November 21, 2026

A bounded 128 MiB real-stdin fixture with a planted center at 96 MiB minus four
bytes produced different Pat5 statistics under serial and threaded CLI batching.
Original 0.96 default and rewrite `-singlethreaded` displayed `Pat5(*,g)`
`R=167.9`, while original `-multithreaded` and rewrite default displayed
`R=169.3`. All four executions completed successfully with Expanded/raw input;
the rewrite used reference-compatible arithmetic. Original serial/threaded
managers use 32/128 MiB batches respectively. This demonstrates a statistical
consequence of the rewrite's changed execution default, without establishing
a new Pat5 counting defect.

See [D001](../departures-from-upstream.md#d001--supported-feature-subset) and
[D006](../departures-from-upstream.md#d006--measured-resource-use) for the disclosure
and pending default/compatibility decision. The serial/parallel state oracle
uses identical caller slices and cannot detect this CLI partition difference.
The departures audit retains the fixture, probe and raw captures locally.
No counting or execution semantics were changed for this disclosure.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `Pat5, test_blocks, five tail centers, batching`. See [search scope](README.md#search-scope) for coverage and limits.
