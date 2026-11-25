# Contributing

The repository's contributor rules are in this document and [testing](testing.md).
Build, test and maintenance work requires no installed agent skills, private
conversation history or T3 Code setup. Personal tools may assist the workflow;
the repository remains the authority for its requirements.

## Build and verification

Use the locked Nix environment through `scripts/dev` and the prerequisites
in [testing](testing.md). The [README](../README.md#build-and-run) gives the build
and launch commands. Use `tools/zig_run.py` for an isolated local build cache and
automatic cache cleanup and a default install prefix of `.work/install`. Explicit
`--prefix` choices are preserved. Keep temporary captures and executables in
ignored `.work/`; preserve original fixtures outside it.

Run the compiler, formatting and warning checks appropriate to the affected
targets before adding other analysis tools. Launch the Debug executable and
exercise the changed CLI behavior as well as focused checks. Distinguish actual
runtime evidence from source inspection. Reuse earlier results only when their
relevant inputs and environment are unchanged; never weaken a failing check.
Report unavailable prerequisites and remaining coverage gaps.

Before every commit, run `scripts/check-deps` and report available updates without
changing locks. Unavailable update sources fail the check. `scripts/pre-commit`
runs that check and the [full ReleaseFast suite](testing.md#full-test-suite),
including all six fresh SFC comparisons.
`test-unit` is partial validation. Review the complete diff, preserve unrelated
work, and repeat checks invalidated by later edits. Keep topic work on its own
branch; review and verify the integrated result before publication. A local
commit does not by itself authorize a version change or publication.

## Design and ownership

Fit the existing [architecture](architecture.md). Prefer fewer concepts and
direct, inspectable code. Keep authoritative state, immutable definitions,
relationships and derived calculations distinct. Normalize shared facts and
represent relationships explicitly; an index is often more useful than another
pointer or object. Each mutable state set has an explicit owner. Prepare fallible
work privately and publish shared changes only after dependent work succeeds.
Runtime queues and scratch buffers retain their actual ownership and lifetimes.

Keep I/O and other effects at clear boundaries. Separate calculations from
orchestration where it makes failures easier to isolate. Preserve imported
libraries' required identity and mutation rules. Agree on added dependencies
before adopting them. Large layout, scheduling or
state-model changes need a concrete proposal before implementation; these
principles do not require reorganizing the existing source tree.

Choose data layouts from workload and access patterns. Keep hot counters dense,
group data by lifetime, and use bounded reusable buffers where appropriate.
Remove unnecessary work before adding batching, vectorization or concurrency.
Require stronger measurements for more complex optimizations. Comment
non-obvious constraints near the code; name tunables without turning intrinsic
algorithm constants into configuration.

Internal relationship and state checks belong only in test builds. Compile them
out of normal executables, including Debug builds. Runtime input checks and
documented numerical-error handling stay at their existing boundaries. Before
changing the structure or meaning of saved or active development state, agree
on preservation, migration or recreation, and recovery requirements.

## Compatibility and reference evidence

Read the [reference contract](testing.md#reference-compatible-results) and current
[departures](departures-from-upstream.md) before an upstream comparison or behavior
change. Keep fetched reference sources immutable and preserve release provenance in
[reference provenance](reference-source.md). Ordinary tests read original fixtures;
they never recapture or replace them with output from the implementation tested.

Separate intended compatibility, current departures and upstream-defect evidence.
Record each suspected defect with its source, valid reproduction, status and
current handling in `docs/upstream-bugs/`. Finding an upstream defect alone does
not authorize a behavior change. Update the departure log in the same change
for accepted differences in commands, results, errors, defaults or resources;
keep stable IDs ordered by user impact. Preserve existing comparison rules.

Arithmetic remedies need independent mathematical or original-source controls,
plus the retained byte/report comparisons. Preserve state walks, seeding and
stream consumption when defining imported generator arithmetic. Both result
modes share approved safety fixes; improved statistical calculations remain a
separate, documented policy. Better arithmetic does not establish recalibration.

## Records and proposals

Keep the README for introduction and setup, and `docs/` for maintained usage,
design and compatibility records. Agent instructions are private working material,
not public build or documentation prerequisites.
Essential instructions and reproduction recipes must be understandable from the
repository. References to ignored dependencies and generated outputs need tracked setup
that recreates them. Keep required evidence tracked and project references
repository-relative. Use `.work/` only for disposable task scratch; move specifically required evidence or recovery out before finishing. The [publication boundaries](publication.md) apply to both repositories.

Keep agreed unfinished work and proposals as individual records in the independent private companion. A proposal identifies the problem, relevant code, expected
benefit, tradeoffs, evidence needed, and a trigger for reconsideration. Rank
proposals by return on effort and risk, with `Confidence: N/10`. Move implemented
behavior into maintained documentation and remove obsolete backlog entries.
Do cohesive improvements in scope; explain substantial scope changes first.
