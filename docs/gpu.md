# Metal and Vulkan execution alongside CPU workers

`-gpu` (also `--gpu`) enables GPU execution for the Expanded battery (`-te 1`).
Metal is preferred on macOS; Vulkan supplies the portable backend. Both offload
eligible raw-byte Mod3/DC7 histograms and FPF/4 with an independent owner.
The Vulkan FPF owner also derives FPF/16 from the same windows.
Both current backends keep C8 classification and child counting on the CPU pool.
Vulkan retains GPU C8 classification for older libraries without FPF support. CPU execution remains the default, and core
GPU requests fail before consuming stdin. Statistical scoring remains on CPU.

## Build and run

Commands use the [run-specific cache helper](testing.md#run-specific-build-caches).

On macOS, the native backend needs only the installed Metal/Foundation frameworks
and system C++ runtime, without the Vulkan SDK:

```sh
python3 -B tools/zig_run.py build -Dmetal=true
.work/install/bin/RNG_test stdin16 -te 1 -tf 2 -gpu < random-data.bin
```

This is a Debug development build; add `-Doptimize=ReleaseFast` for timing.
The backend is validated on Apple M2. Other Metal devices require validation.
The application's existing macOS/Linux platform scope remains applicable.
CPU-only builds need neither GPU option.

The default Nix environment has no Vulkan SDK or runtime dependency. The Zig
runner selects the pinned optional environment only when `-Dvulkan=true` (or
`-Dvulkan`) is enabled. CPU and Metal builds do not download it:

```sh
python3 -B tools/zig_run.py build -Dvulkan=true
./scripts/vulkan .work/install/bin/RNG_test stdin16 -te 1 -tf 2 -gpu < random-data.bin
```

`scripts/vulkan COMMAND...` explicitly selects the optional environment for
direct Zig commands, GPU binaries or an interactive shell. Its environment output
and SDK are separate lazy flake outputs; neither is realized by a CPU build.
The optional environment supplies the SDK layout selected by `VULKAN_SDK` and
retains its own GC root. Newly captured jobs retain that complete environment;
existing frozen environments and explicitly recorded SDKs are not reselected.
On ARM64 macOS, [the SDK derivation](../nix/lunarg-sdk.nix) preserves LunarG
1.4.363.1, including its shader compiler, MoltenVK and KosmicKrisp. It verifies
the official archive checksum and uses copy-only installation inside the Nix
store, without writing system-wide SDK files. Copy-only extraction and 77 hardware
checks per driver passed in the locked environment on ARM64 macOS, using both
MoltenVK and KosmicKrisp. A short Expanded run matched all 135 displayed CPU rows.

Linux retains the shared catalog's Vulkan headers/loader and SPIRV-Tools
SDK 1.4.363.0 sources and shaderc 2026.1. These have evaluation-only coverage;
their upgrade and native GPU/runtime validation remain outstanding. A real GPU
and its operating-system driver remain prerequisites.
No fallback to a host SDK or a different compiler is permitted. `-Dvulkan-sdk`
can select a separately recorded immutable SDK for explicit comparisons.
There are no windowing or graphics-surface dependencies. Vulkan uses 1.1 compute
and 32-bit shader integers; optional portability extensions are enabled only when
advertised. Counter validation on other GPU/OS combinations remains necessary.

The libraries install under `zig-out/lib`. macOS first loads `libpractrand_metal`
and tries `libpractrand_vulkan` if the Metal library cannot be loaded. Linux loads
`libpractrand_vulkan`. Both options may be enabled in one build.
`PRACTRAND_GPU_LIBRARY` selects an explicit library path, including frozen
benchmark libraries or an explicit Vulkan run on macOS. An explicit selection
never falls back to a different library. After initialization starts, allocation,
shader and execution failures propagate; there is no silent CPU/GPU retry.
The startup banner identifies the selected device/backend.

The older `-Dmetal-fpf=true` spelling is a compatibility alias for the complete
Metal backend. Its former `libpractrand_metal_fpf.dylib` path is also installed
as a compatibility copy; it now runs independently of Vulkan. CPU-only runs do
not load any GPU library. The private backend C ABI remains versioned. Version 11's original counter entry
point and six-level Mod3 result layout remain usable. Both current backends advertise an
optional `pr_gpu_mod3_count_v1` / `pr_gpu_mod3_layers_v1` pair for nine-level
Mod3 counting; the executor accepts six through nine complete levels. Older
libraries continue with six. Complete 1 KiB calls keep the packed
upper-level handoff and rolling history aligned at each supported depth.
Vulkan also exposes the optional `pr_gpu_count_pair_v1` entry point. At nine
Mod3 levels, the executor can upload a bounded chunk once and submit both
Mod3 and DC7 before one completion wait. The two result ranges remain borrowed
until merged. Libraries without this entry point, including native Metal, retain
the existing separate calls; ABI version 11 and its original entry points remain.


## Ownership and scheduling

One executor owns the selected backend and persistent scratch. Vulkan prefers a
discrete GPU, otherwise a hardware compute device; CPU-type Vulkan adapters are
rejected. Metal selects the system default device. Only the dedicated service
thread submits Mod3/DC7 work and, with Vulkan, C8 work; the independent FPF owner is described below. It uses the same
borrowed-request service as CPU input counting, with FIFO requests for independent
streams. Each stream still consumes its own input and nested folds in order.
Construction and teardown occur before and after the service's lifetime.

Independent top-level Expanded streams submit CPU families to the existing shared
pool and eligible GPU families to that service. With FPF support, both backends
run the complete C8 family on a CPU pool job. Older Vulkan libraries without FPF
support create ties with the existing CPU Arbee generator, perform bounded GPU
classifications and count C8 children on their CPU family job. Counter calls return exact bounded
32-bit integer deltas, merged into the original CPU 64-bit histograms; rolling
state and sparse upper-level propagation remain current. A later small CPU call
therefore needs no migration or ownership reset. There is one shared GPU scratch
set across streams, rather than per-stream histogram replicas.

CPU families, counter requests and FPF requests all join before input, stack
request records or battery state can be reused, including failures. Vulkan calls below 64 KiB use CPU C8 classification; this
remains an initial heuristic. Histogram offload starts at 4 MiB, including the
quarter-fold calls that were excluded by the earlier 8 MiB experiment. Missing
counter capabilities retain those families on the CPU. Allocation or execution
failures propagate; partial GPU progress is never silently replaced or dropped.

Threaded GPU Expanded input uses a cancellable reader feeding the original
128 MiB statistical buffer. For descriptor input, FPF-capable configurations
reserve four 64 MiB reader slots, for 384 MiB total input payload; libraries
without FPF retain four 32 MiB slots and 256 MiB total. Capacity stays at four slots for the primary workload;
separate bursty-input gains did not establish a RAM-efficient automatic growth
policy. Only copied,
accepted bytes reach statistical tests. Byte limits bound prefetch; an early stop
can leave prefetched bytes unused. Cancellation joins the reader and preserves
the borrowed stdin descriptor. `-singlethreaded` uses the original input path;
its GPU service still runs alongside the main counting thread.

Built-in generators use one producer thread. Paired Vulkan FPF uses four
32 MiB slots; other configurations retain their descriptor-input capacity.
The producer publishes at most 1 MiB per fill and can generate ahead across
checkpoints; logical 128 MiB counting calls and 256 MiB outer steps remain
unchanged. Generator failures surface after previously published input has been
consumed. Cancellation waits for the current bounded fill and joins the producer
before destroying the borrowed generator. Built-in input therefore reserves
256 MiB with paired Vulkan FPF, 384 MiB with single-family FPF (including
native Metal), or 256 MiB without FPF.

FPF-capable libraries use two host service threads beyond the counting cap:
one for counters and one for FPF. FPF is submitted before CPU family jobs, so a
CPU worker does not wait on its GPU fence or scratch lease. Older Vulkan libraries
without FPF use one service thread, which also performs CPU tie work; C8 children
stay on their CPU family job. Threaded GPU input adds one reader thread.
With paired Vulkan counters, the pool uses the smaller of the available CPU count
and the maximum number of independent counting families across the top-level
streams. This gives eight counting threads on the eight-core M2. Native Metal
and Vulkan configurations without paired counters use up to eight counting threads. CPU-only execution
uses up to four. All counts include the caller.

Original input, nested-fold, 16 MiB transform input, 4 MiB flush, and checkpoint
boundaries are preserved. Threaded Expanded outer calls remain 128 MiB, even
though the inspiring C++ pipeline uses 32 MiB. One Arbee word supplies eight
classifications, reserving eight consecutive bits per classification regardless
of ties. The CPU and GPU paths share cached remaining bits; generator progress
and remaining bits are published only after a successful GPU classification.
See [the consumption departure](departures-from-upstream.md#d018--c8-uses-every-arbee-output-bit).
All tests, folds, rows and numerical validation remain.

C8 input/tie/output and CPU tie staging reserve about 21 MiB. Counter scratch is
lazy, shared and bounded; the current performance record lists the
selected payload budget. The earlier study records historical
resident-memory observations. These
capacities exclude driver allocation/alignment and statistical storage. Mapped
noncoherent uploads and readback are explicitly flushed/invalidated. Vulkan
uses 32-bit shader arithmetic and atomics; native Metal FPF uses `ulong` windows.
Metal shares the service input buffer between classification and counters. At
16 MiB counter capacity its byte intermediates reduce nominal counter scratch
from the preceding 66 MiB to 30 MiB. On Vulkan, classification and counters share the upload buffer. DC7
appends its 1 KiB lookup after the current input. The Mod3 shader reads the
original bytes at every level and writes the packed upper-level handoff directly.
One additional 2.74 MiB buffer holds both histograms and the handoff. Eight
per-invocation counters combine repeated bins before global atomic additions.

Metal keeps its 64 MiB FPF limit and eight histogram replicas. Vulkan advertises
its FPF input capacity through the same optional ABI. With a 16 MiB counter
capacity, the Vulkan FPF input limit is 32 MiB. Each FPF bin has two counts:
windows aligned for FPF/16 and the remaining FPF/4 windows. Their sum gives
FPF/4. Runs of equal input words reuse the same windows; equal halfwords also
preserve FPF/16 alignment after four nibble shifts. The service merges both
histograms before releasing its lease. Older libraries continue FPF/16 on CPU.

Vulkan binds mapped device-local memory directly. When the mapped memory is on
another heap, the backend allocates a shader buffer and records the upload or
readback copy in the same command buffer. Six buffers on the M2 request
60.24 MiB at the default capacity; the CPU tie staging adds 2 MiB. These
figures exclude statistical storage, driver internals and allocation padding.
Mapped noncoherent ranges are flushed before submission and invalidated after
fence completion. The upload follows Vulkan's queue-submission memory guarantee.
[Khronos synchronization examples](https://docs.vulkan.org/guide/latest/synchronization_examples.html)

For paired Vulkan histograms, the service tries Mod3 tiles of 8, 16, 32, 64 and
128 samples per invocation. DC7 uses twice the selected width. It rotates through
the five choices twice on real submissions, groups uploads by their base-two
size and compares completion time per KiB. After those ten calls, the width of
the fastest observation stays in use for that size class. Calibration counts
every input once and keeps its observations in the running process. The
32 GiB SFC32 comparison records the timings
and structured-input checks.

## Verification

```sh
python3 -B tools/zig_run.py build test-gpu -Dmetal=true
python3 -B tools/zig_run.py build test -Dmetal=true -Doptimize=ReleaseFast
```

Use `-Dvulkan=true` without `-Dmetal=true` to check the Vulkan backend separately.
When both options are enabled, hardware checks select Metal. Both enabled native
libraries are compiled with fatal warnings; Vulkan also validates SPIR-V.

`test-gpu` requires a real usable GPU and fails rather than silently skipping.
Hardware checks always execute, so a build-cache hit cannot hide a changed driver
or validation configuration. They check classification bytes against the CPU
transform, whose separate oracle counts input bits directly. Cases include four fixtures, three seeds, four input/
output alignments, empty input, pair tails, small/large/reused buffers, and exact
RNG progress. The ordinary CPU suite checks the shared service's independent
progress, failure joining, reuse, and teardown without requiring a GPU.
The counter checks compare every bin and rolling/warmup/phase/history field
through mixed CPU/GPU calls and forced internal splits, including seeded totals
above 2^32. Native checks exercise both nine-level and legacy six-level Mod3
entry points, including random, zero, all-one and repeating-byte input. A
complete-state oracle preserves two original 128 MiB calls.
Paired-counter checks additionally change bytes at a reused address, seed high
existing totals, split across capacity, and enter with an odd DC7 CPU history.
They compare complete state through optional-pair and six/nine-level fallbacks.
These checks do not measure performance.

With either GPU build option, `test` includes the selected hardware checks alongside the normal
full suite. `check` also compiles the C backend with warnings treated as errors,
compiles the shader and validates its SPIR-V. Without the option, the ordinary
CPU suite remains usable without GPU dependencies. For Vulkan SDK validation diagnostics,
set `VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation` in the activated environment.
See [testing](testing.md) for the full-suite and frozen-input contracts.

## Native Metal backend

Metal implements C8/Mod3/DC7 directly and keeps the native FPF owner independent
of the counter service. A second host service submits FPF while CPU family workers
remain available. A mutex still covers FPF submission, completion, readback and
CPU histogram merging, including direct callers outside the service.
Its scratch is shared across streams rather than replicated per stream. Exact
bounded 32-bit deltas update the existing CPU 64-bit totals, preserving later CPU
handoffs and all stream histories. Metal resources remain owned through completion.

`python3 -B tools/zig_run.py build test-gpu -Dmetal=true -Doptimize=ReleaseFast`
exercises classification, counter handoffs, complete battery state, concurrent
FPF leases, failed-call reuse,
and FPF windows covering every exponent plus constant-zero/one inputs.
## Shared frozen Vulkan libraries

New retained jobs root their Nix environment closure; they do not create another
shared dependency installation. The historical pre-Nix SDK remains under
`~/VulkanSDK/<version>`. Old frozen benchmark runtimes share their exact libraries in
`~/.local/share/dev-pool/vulkan/<sdk-version>/<content-hash>/`.
For recovery/maintenance of those historical runtime copies only:

```sh
python3 tools/pool_vulkan_runtime.py --sdk-version 1.4.363.1 path/to/runtime
```

The helper verifies SHA-256 hashes, publishes an immutable bundle, and replaces
only those three library files with links. Existing ICD JSON, manifests, private
backends, executables and results keep their paths and bytes. Identical bundles
are reused; different versions or bytes get separate bundles. It also writes
`vulkan-pool.json` beside the links, recording their SDK identity and hashes.
Keep this dependency descriptor when retaining or moving a frozen runtime.

If the shared bundle is missing, restore it from matching SDK libraries:

```sh
python3 -B tools/pool_vulkan_runtime.py --sdk-version RECORDED_VERSION \
  --restore-from /path/to/that/sdk/macOS/lib path/to/runtime
```

Recovery checks all three source hashes against `vulkan-pool.json` before
publishing or changing links. A different SDK build or a present corrupt bundle
is rejected. Existing pooled runtimes need one normal helper run while their
links still work to create this descriptor. Recovery requires the recorded SDK
bytes; it never substitutes the current latest SDK for frozen dependencies.
This helper shares/restores libraries, not a complete distributable Vulkan
package: driver manifests and SDK-dependent loading paths remain separate.
Never point a
frozen experiment at a moving `latest` SDK or Homebrew symlink, and do not remove
pooled bundles while retained experiments reference them.
