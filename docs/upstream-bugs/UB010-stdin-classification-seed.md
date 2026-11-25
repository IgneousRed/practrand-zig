# UB010 — Stdin seed labels do not fix randomized classification

**Status:** Probable reproducibility bug. Source behavior is confirmed; author
intent is unresolved. Preserved in the rewrite. **Confidence: 7/10.**

With stdin, `-seed` labels the report but does not seed the auxiliary HC256 RNG
used to initialize `[C8]`. Identical input and identical labels can therefore
produce different classification results.

In original `tools/RNG_test.cpp`, the automatically seeded `known_good` HC256
first supplies a random 32-bit `seed_low`, with `seed_high` zero. A supplied
`-seed` replaces those values only if the input RNG supports seeding. HC256 is
then reseeded from those values regardless of input type. In `src/tests_core.cpp`,
`classify128to8::init` seeds its private `arbee` RNG with `known_good->raw64()`;
that RNG supplies classification tie-breaking bits. For stdin, neither the
random 32-bit seed nor the derived `[C8]` seed is reported.

The probable bug is coupling control of internal test randomness to whether
the input source supports seeding, leaving that randomness uncontrollable and
unrecorded for stdin. With a seedable built-in RNG, `-seed` controls both the
tested RNG and HC256. However, the 0.96 help explicitly permits arbitrary strings
as stdin seed labels. This supports intentional label behavior, but does not
establish that unreproducible internal randomness was intentional, or that the
author specifically intended numeric stdin labels to seed `[C8]`.

Historical diagnostic comparisons fixed the auxiliary RNG explicitly. Current
parity checks compare production `[C8]` row names; its values remain
randomized. Recording this probable bug does not authorize changing the
documented label interface or the rewrite's seeding behavior.

Evidence: seed and reproducibility research and
Expanded validation.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `stdin -seed, classify128to8, C8, auxiliary HC256, reproducibility`. See [search scope](README.md#search-scope) for coverage and limits.
