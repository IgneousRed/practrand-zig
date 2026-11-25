# UB001 — FPF/64 depends on the first checkpoint/input call

**Status:** Confirmed defect; fixed in the rewrite. This is an intentional
upstream bug fix, recorded as [departure D010](../departures-from-upstream.md#d010--fpf64-checkpoint-independent-sampling-bug-fix).

For identical bytes, FPF/64 results can depend on when input is first delivered
to the test. In original `src/tests_core.cpp`, `FPF::test_blocks` starts at
32-bit index 0 on its first call and index -1 on subsequent calls, advancing by
two words. Thus the first call samples one 64-bit alignment and later calls
sample the other. Transform buffering makes the first checkpoint relevant:
`Transform_Baseclass` normally flushes at 4 MiB of transformed data and flushes
complete blocks aggressively during `get_results`.

The user identified the original first-checkpoint bug during the Expanded port.
Our standalone comparisons matched, but the initial long extra-folding comparison
with a 32 MiB first checkpoint diverged specifically in folded FPF/64 rows when
the rewrite fed transformed data earlier than upstream. The initial compatibility
correction preserved upstream's flush/checkpoint schedule. The subsequent approved
bug fix keeps FPF/64 windows at byte offsets 0, 8, 16, ... throughout the stream,
using the same alignment on every input call and no cross-call window. Identical
input prefixes now produce identical FPF/64 histograms and results regardless of
the first checkpoint or batching, including folded streams. Results can
consequently differ from untouched upstream after its first input call.

Verification compares all four FPF strides across five first-checkpoint sizes
and subsequent 37 KiB batches, including intermediate result requests. FPF/32,
FPF/16, and FPF/4 retain their existing sampling. The retained check is in
[the FPF kernel test](../../src/battery.zig). The separate
nominal sample-count question remains [UB011](UB011-fpf-nominal-sample-count.md);
this fix does not change the result normalization or calibration.

The subsequently added [independent controls](../fpf64-verification.md) compare
all histogram bins with direct bit-window enumeration and retain 14 original
single-call scoring results. The original capture avoids the later-call phase
switch, so it independently checks the approved alignment and reference scoring.
The existing batching check and ordinary fixture exclusions remain unchanged.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Disclosed.

Exact match: [SourceForge ticket #25](https://sourceforge.net/p/pracrand/bugs/25/), reported October 27, 2026 by igneous-red; status **open** when checked. It reproduces different folded FPF/64 statistics at shared byte counts after changing the first report, and identifies the same first-call/subsequent-call sampling phase change. The ticket has no discussion replies. Disclosure is established; maintainer confirmation is not.

Search terms: `FPF/64, reporting checkpoints, first input call`. See [search scope](README.md#search-scope) for coverage and limits.
