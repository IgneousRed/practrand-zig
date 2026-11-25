# State and computation boundaries

The project follows its repository-owned [contributor guidance](contributing.md).
Its streaming statistical kernels retain their dense counters, specialized loops,
batched transforms, and bounded worker pool.

The input-counting and GPU executors use the same dedicated-thread service from
`worker_pool.zig`. Both use caller-owned FIFO request nodes; ordered input reuses
one request while independent GPU roots may queue several. The service publishes
each completion and failure before callers reuse their input or context, and
teardown drains every request.

[main.zig](../src/main.zig) owns command-line handling, clocks, stdin,
checkpoint scheduling, input selection, and the decision to stop. [report.zig](../src/report.zig)
owns report output. [builtin_rngs.zig](../src/builtin_rngs.zig) owns a selected
built-in generator through a buffered C ABI. Threaded GPU Expanded input lends
the generator to the bounded reader's producer until teardown joins it; other
input paths fill buffers directly. The adapter compiles unchanged vendored
RNG sources, with portable entropy/block helpers and the active dummy algorithm;
it does not call original statistical batteries. Generator state and pending
partial native words belong to that input owner, independently of C8's Arbee state.

The local arithmetic adapters mirror affected private generator state because
the original classes do not expose those fields for a narrow method override.
Their literal definitions live in [builtin_rngs.cpp](../src/builtin_rngs.cpp) and
[builtin_rng_arithmetic.h](../src/builtin_rng_arithmetic.h); building does not generate or patch vendor sources.
Candidate implementations with public state reuse their existing ownership and
walk methods. Accepted arithmetic departures are recorded in D025/D026/D028;
D029 defines the explicit legacy and fixed Ranrot choices.

[Arbee](arbee.md) owns its five-word generator state and implements deterministic
seeding, output, and entropy mixing. Expanded initializes every classification
stream with the fixed OddPhi seed defined in `expanded.zig`; stream initialization
has no auxiliary seed input or OS entropy acquisition.
Each classification stream also owns the unconsumed portion of its current
Arbee word. The CPU classifier and GPU tie staging consume this shared `TieBits`
state in fixed groups, independent of the number of ties, retaining all bits
across calls. A successful GPU classification publishes both generator progress
and the remaining bits together.

[streams.zig](../src/streams.zig) owns the stream records and their nested folding
relationships. Relationships use indexes into the stream table. The worker pool
is supplied to operations rather than stored in every record. Transform parameters
and report prefixes are distinct: a nested transform's parameters describe its
immediate input, while its prefix describes the corresponding original stream.

Counting state is owned by each battery and its transform buffers. Histograms,
retained samples, random-generator state, and accumulated statistical summaries
contain information about consumed input; they cannot be discarded as caches.
[suite.zig](../src/suite.zig) selects the core or Expanded implementation. The
root battery's block count also drives checkpoint scheduling; the input loop
does not maintain another copy.
The numerical transforms in [statistics.zig](../src/statistics.zig) operate on
explicit inputs and private working data. The run selects its arithmetic policy
at initialization; each scoring job receives that policy through `Results`.
Counting state and GPU kernels remain shared between result modes. The
[reference contract](testing.md#reference-compatible-results) defines their numerical differences.

Derived scores live separately in per-stream result caches. Each scoring job owns
a temporary arena for calculation, including temporary histograms and models.
After scoring succeeds, result rows and names are copied into a compact output
arena and replace the previous cache atomically. Failure leaves the previous
cache intact. Scoring scratch is released when that job finishes. Shared core
checkpoint models and report scratch belong to the checkpoint caller.
Expanded's compact Distribution-model cache belongs to the stream owner and is
bounded by entry count and payload bytes. Checkpoint preparation admits models
before scoring, protecting current-checkpoint entries from eviction. Scoring
borrows immutable models or constructs an uncached model in its own scratch;
all scoring jobs join before the next cache preparation or teardown.

The run arena owns stream records, transform buffers, immutable Distribution and
Mod3 probability tables, and shared NearSeq3 Hamming models. Tables are built once
from explicit inputs and then read by scoring jobs; there are no readiness flags
or mutable global probability tables. Battery teardown releases independent
histogram mappings and growing workspaces; stream teardown releases result arenas.
Allocation APIs taking the run allocator require its arena lifetime; their
`deinit` methods release only independently owned resources.

Histogram layouts name their slices while preserving a single contiguous mapping.
Family enums define both dispatch identities and job counts. Calibration lookups
return indexes into the immutable observation catalogue.

Internal state and relationship constraints are checked only in test builds,
including ReleaseFast tests. They add no checks to normal executables, including
Debug builds. Input validation and documented invalid-result errors remain runtime
behavior. See the project rule in [contributor requirements](contributing.md#design-and-ownership).

## Checkpoints

A checkpoint first flushes complete folded blocks through nested streams in
their established order. Each changed battery then explicitly prepares its
checkpoint, including the Expanded classification flush, before scoring it.
Preparation and scoring remain parallel across independent streams. Result
collection reads the prepared battery state; it does not perform that flush.
The report receives the collected results in stream order.

## CPU counting and input ownership

For threaded CPU Expanded runs, independent top-level streams submit their work
to one shared pool. Each stream still processes its own input, nested transforms,
classification flushes, and families in the established logical call sequence.
The pool borrows job records until their group joins. A caller waiting for a
nested group executes ready work from the same queue; no worker is reserved for
a waiting parent. Each group drains before returning its first observed error.
The serial fallback retains its existing stop-on-error behavior.

The input loop and one counting service alternate two 128 MiB buffers. Only one
logical update is pending; the reader may fill the other buffer while counting
uses its immutable slice. The service joins before buffer reuse, every outer
step's clock observation, checkpoints, and teardown. The outer step remains at
most 256 MiB, each logical call remains at most 128 MiB, and Expanded's 16 MiB
transform input and 4 MiB flush boundaries remain intact. Cross-stream counting also applies to GPU Expanded. Its cancellable input reader
keeps independent bounded slots feeding the same original logical calls; see
[GPU ownership and resources](gpu.md). Core and serial input retain their paths. Pool changes also serve existing scoring
and family jobs. See the measurements and tradeoffs.

Keep the transform input and flush boundaries in [expanded.zig](../src/expanded.zig)
when changing orchestration: they affect upstream-compatible Pat5 behavior.
See [testing](testing.md) for the current parity and isolated kernel checks.

## Optional Metal/Vulkan executor

[The GPU path](gpu.md) passes one run-owned executor through the stream owner to
Expanded updates. The counter service owns selected Mod3/DC7 updates. Both current
backends keep the C8 family on the CPU pool. With older Vulkan libraries without
FPF, that family lends a bounded classification transform and RNG state to the
counter service, joins it, then performs child counting on its CPU owner.
Each family has one owner for the duration of its update. A separate FPF service
submits before CPU families and retains its backend lease through completion and
integer merging. With the optional paired Vulkan FPF entry point, this service
owns both FPF/4 and FPF/16 for that call; otherwise FPF/16 stays with the CPU.
Every owner joins before the update publishes its block count
or releases input/job records, including failure paths. Vulkan's optional paired
counter entry point shares one upload and completion wait; both result regions
remain borrowed until the service merges them. Both backends keep persistent scratch;
CPU histograms and rolling state remain authoritative. The CPU classification
transform and its independent oracle live in `classification.zig`.

## Open architectural decisions

There is no general relational engine or automated constraint dependency checker.
Numerical updates mutate privately owned streaming state and may leave partial
progress on failure; the CLI terminates the run on such errors. Recoverable
transactions would need an agreed boundary and failure contract before changing
this behavior. Initialized batteries also continue to require explicit allocation;
there is no allocation-free default battery.

The development-state preservation policy remains unspecified, as recorded in
[contributor requirements](contributing.md#design-and-ownership). This separation does not migrate saved development
state or define a statistical save/resume format.
