# practrand-zig

A Zig rewrite of the statistical RNG testing tools from
[PractRand](https://pracrand.sourceforge.net/), created by **Chris Doty-Humphrey (orz)**.
The goal is a faster replacement with familiar commands and reports, documented
compatibility gaps, and explicit fixes for confirmed upstream bugs.

Version **0.2.0** is a working subset of PractRand 0.96. It implements the core
and Expanded batteries, stdin, direct files and built-in RNG input, raw/standard/extra folding,
and serial or parallel execution. The original active generator, candidate,
transform and catalog factories are available; see [built-in RNGs](docs/builtin-rngs.md).
The special Birthday (`-te 10`) and experimental (`-te 20`) batteries are
[intentional omissions](docs/departures-from-upstream.md#d021--special-and-experimental-batteries-intentionally-omitted),
with no plans to implement either. The unfinished alternative report format and
upstream self-test commands remain unsupported.
Seed testing supports the original walk plus reflected and balanced Gray walks;
see [seed testing](docs/seed-testing.md). The original `-ttep` entropy-pooling
target is available with its setup checks and documented upstream limitations;
see [entropy testing](docs/entropy-testing.md).

The current platform scope is 64-bit little-endian macOS and Linux. Native
validation has been on ARM64 macOS; Linux runtime behavior remains unvalidated.
Testing other operating systems and architectures is planned after GitHub publication.
Small floating-point differences can occur across architectures. Reference
comparisons require matching displayed results with documented corrections;
binary numerical identity is not promised. Expanded FPF/64 intentionally fixes an upstream checkpoint-dependent
sampling bug, and ordered rarity scoring corrects the confirmed Gap-16:C
cumulative-rounding defect. The historical Gap-16 input has not been revalidated.
Read the [compatibility departures](docs/departures-from-upstream.md) and
[upstream bug status](docs/upstream-bugs/README.md) before replacing an existing installation.

## Build and run

Install [Nix](https://nixos.org/download/) once; the launcher enables flakes for
its commands. Project compiler and dependency versions are locked by `flake.lock` and `nix/`; builds
never select Homebrew tools or update locks implicitly. Enter the environment:

```sh
./scripts/dev bash
```

Run the commands below inside that shell. The launcher works from Git checkouts
and source archives, stages only declared Nix inputs, and keeps dependencies in
`/nix/store` with a local GC root. Writable builds and captures remain outside
the store. It reports a missing Nix prerequisite rather than installing another
package manager. Compiler changes require an explicit lock update followed by the
[full verification suite](docs/testing.md#full-test-suite).
The default environment excludes Vulkan; enabling its build option through the
Zig runner selects the [optional Vulkan environment](docs/gpu.md#build-and-run).

The executable includes statistical kernels and calibration data. PractRand
acquisition recipes and original fixtures are tracked; no sibling checkout, Python package
installation or prior cache is required. Required upstream source is acquired lazily into the immutable `.vendor/PractRand` view; see [reference provenance](docs/reference-source.md). Native OS/GPU APIs and the locked SDK
requirements are described in the [GPU guide](docs/gpu.md#build-and-run).
Nix environments cover ARM64 macOS and 64-bit little-endian Linux.
The native LLVM bundle requires macOS 26 or later. The shared
nixpkgs revision has no native Intel-macOS environment. Application cross-targets
are retained; Linux runtime and additional GPU devices still require validation.

```sh
python3 -B tools/zig_run.py build -Doptimize=ReleaseFast
.work/install/bin/RNG_test --help
.work/install/bin/RNG_test stdin64 -tlmin 1M -tlmax 1G < random-data.bin
.work/install/bin/RNG_test 'file64(random-data.bin)' -tlmin 1M -tlmax 1G
.work/install/bin/RNG_test sfc64 -seed 0 -tlmin 1M -tlmax 1G
.work/install/bin/RNG_test --list_recommended_rngs
```

Stream inputs are `stdin`, `stdin8`, `stdin16`, `stdin32`, `stdin64`, and
`file(PATH)`, `file8(PATH)`, `file16(PATH)`, `file32(PATH)`, `file64(PATH)`.
They also work inside transforms, such as `'As8(file64(random-data.bin))'`.
See [input expressions](docs/builtin-rngs.md#stream-inputs-and-special-wrappers).
Select the
core battery with `-te 0` (the default), or Expanded with `-te 1`. Folding is raw
(`-tf 0`), standard (`-tf 1`, the default), or extra (`-tf 2`). Length suffixes
use binary units, counting bytes in normal mode, seeds in `-ttseed` mode,
and entropy strings in `-ttep` mode
(an explicit `B` suffix always counts bytes). Parallel counting uses up to four threads by default (eight with GPU execution),
bounded by the available CPU count. Threaded CPU Expanded runs use one additional
host thread to overlap input with
counting. `-singlethreaded` selects serial execution. See the
[resource requirements](docs/departures-from-upstream.md#d006--measured-resource-use)
and [CPU ownership](docs/architecture.md#cpu-counting-and-input-ownership).

```sh
.work/install/bin/RNG_test stdin64 -te 1 -tf 2 -tlmin 1M -tlmax 1G < random-data.bin
```

Extra folding runs the battery on ten streams and increases CPU and memory use.
Add `--reference-compatible` to select the PractRand 0.96 comparison contract,
with the accepted FPF/64, C8 and error corrections. Sorting, monotonic timing,
parallel/GPU execution and improved diagnostics remain available. Default mode
uses the [precision improvements and portable binary64 policy](docs/numerical-policy.md);
reference-compatible mode retains its previous arithmetic and probability models.
Add `--full-precision` to append 17-digit raw, p-value and suspicion fields without
changing report filtering. Suspicion can retain a finite extreme tail even when
the p-value rounds to zero or one.
Select `-table_wide` to include normalized weight percentages and scores, or
`-table_scoring` to show decimal suspicion, the weight adjustment, and the score.
`-table_narrow` selects the default layout. All three layouts support
`--full-precision`; see [report formats](docs/report-formats.md).
Add `-do_metatest` for the upstream experimental summary of selected result
scores at each checkpoint; `-no_metatest` disables it (the default).
It is a heuristic summary, with the [upstream limitations](docs/report-formats.md#experimental-metatest-summary).
See the [numerical improvements](docs/departures-from-upstream.md#d020--stable-default-g-test-and-dc7-tails)
and [reference contract](docs/testing.md#reference-compatible-results).
Expanded's `[C8]` transform uses Arbee tie breaking with the fixed OddPhi seed
`0x9e3779b97f4a7c15` in every stream. Stdin `-seed` labels reports and does not
change this seed. See the [seeding departure](docs/departures-from-upstream.md#d017--fixed-c8-seed).

Optional [Metal/Vulkan execution](docs/gpu.md) moves eligible Expanded integer
histogram work and FPF/4 to the GPU alongside CPU workers. Vulkan also counts
FPF/16 in the same pass. Both current backends keep C8 on the CPU pool; older Vulkan libraries without FPF retain GPU C8
classification. Build with `python3 -B tools/zig_run.py build -Dmetal=true` on macOS, or use
`-Dvulkan=true` for the portable backend, then add `-gpu` to a `-te 1` command.
Metal is preferred on macOS. CPU remains the default. The [GPU guide](docs/gpu.md) describes ownership, resource requirements and hardware coverage.

## Verification and development

Before every commit, check for newer dependencies without changing locks and
run the full local suite:

```sh
./scripts/pre-commit
```

The full suite runs Zig and Python checks and fresh SFC16/32/64 comparisons in
both result modes through 4 GiB against durable original-reference JSON fixtures.
It neither executes the original tester nor regenerates baselines. The vendored
release stays unchanged. See [testing](docs/testing.md) for prerequisites, limits, and isolated
checks. See [project direction](notes/README.md),
[state and computation boundaries](docs/architecture.md),
[contributor guidance](docs/contributing.md), and [testing requirements](docs/testing.md) for ongoing work.
Required project rules are included in the repository; installed agent skills are optional.

The standalone [SFC8 generator](tools/sfc8.c) uses fixed right shift **1**,
left shift **3**, and rotate left **4**. It seeds all four words equally and
discards nine outputs. Its interface is `sfc8 SEED BYTE_COUNT`; the parity
runner compiles it automatically.

## Credits and licensing

PractRand's statistical tests, algorithms, and original C++ implementation are
the foundation of this project. The vendored source is the official
[PractRand 0.96 release](https://sourceforge.net/projects/pracrand/files/), with
[provenance](docs/reference-source.md) and its [original license](LICENSES/PractRand.txt)
preserved. Upstream dedicates its statistical tests and auxiliary code to the
public domain under CC0 1.0.

This rewrite's original code, tools, and documentation are licensed under the
[MIT License](LICENSE), copyright 2026 practrand-zig contributors.
The vendored PractRand files and imported observations in
[calibration_data.zig](src/calibration_data.zig) and
[permutation_data.zig](src/permutation_data.zig) retain their upstream terms and
notices. MIT applies to this project's original contributions and does not replace
the upstream licensing or restrict rights already granted in upstream material.

The improved normal-tail kernel uses fdlibm rational coefficients under the
preserved [Sun Microsystems permission notice](LICENSES/fdlibm.txt).
Its adaptation and source provenance are recorded in the
[numerical policy](docs/numerical-policy.md#normal-tail-kernel-provenance).

New toolchain/GPU dependencies live in the Nix store with environment GC roots.
Historical frozen experiments retain their exact dependencies in the existing
[Vulkan runtime pool](docs/gpu.md#shared-frozen-vulkan-libraries).
