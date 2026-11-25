# UB002 — Recommended RNG catalog contains removed generators

**Status:** Confirmed catalog defect. Since November 12, 2026, the rewrite supports
active RNG expressions and implements the agreed unavailable-slot handling below.

The recommended set retains removed `xsm*` and `rarns*` names. The advertised
27 entries therefore do not represent 27 working factories; for example,
`RNG_output 'recommended_rngs(12)' name` fails to construct a generator.
Evidence: clean-release factory probes in the
RNG-expression research.

### No-longer-supported RNGs in the upstream catalog

These names remain in the recommended catalog, but their factories are disabled
in PractRand 0.96. Indices are one-based.

| Original index | RNG name | Status |
|---|---|---|
| 12 | `xsm64` | No longer supported by upstream 0.96 |
| 13 | `xsm32` | No longer supported by upstream 0.96 |
| 14 | `xsm16` | No longer supported by upstream 0.96 |
| 20 | `rarns64` | No longer supported by upstream 0.96 |
| 21 | `rarns32` | No longer supported by upstream 0.96 |
| 22 | `rarns16` | No longer supported by upstream 0.96 |

Source: the original catalog (`.vendor/PractRand/tools/RNG_from_name.h`) ([source acquisition](../reference-source.md)) and
`register_recommended_RNGs` in the same file.

**Agreed compatibility handling:** When RNG-expression support is implemented,
preserve the original names, all 27 catalog positions, and their index mappings.
Keep these six slots unavailable and clearly diagnose selection of a
no-longer-supported RNG. Do not remove or renumber entries, substitute another
generator, or invent missing implementations. Keep compatibility catalog output
unchanged; put availability labels in human-readable help/documentation and
selection errors. The rewrite now retains the unchanged original catalog listing,
rejects removed entries (including indexed selections) with a no-longer-supported
diagnostic, and labels them in its additional `--list-rngs` help listing. Focused
checks cover direct/indexed errors and preserved positions; active entries are
checked against original byte vectors. See [implemented coverage](../builtin-rngs.md).

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** Related only.

[Ticket #4](https://sourceforge.net/p/pracrand/bugs/4/) reports a generator-name/documentation mismatch in 0.90, and [ticket #20](https://sourceforge.net/p/pracrand/bugs/20/) concerns a rarns64 implementation defect. Neither discloses the six unavailable recommended-catalog slots and their positions in 0.96.

Search terms: `recommended_rngs, xsm16/32/64, rarns16/32/64`. See [search scope](README.md#search-scope) for coverage and limits.
