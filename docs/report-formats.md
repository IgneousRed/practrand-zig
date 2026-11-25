# Report formats

The finished PractRand 0.96 layouts are available in both improved and
reference-compatible result modes. The last table option selects the layout,
independently of the order of filtering options.

1. `-table_narrow` is the default: test name, raw statistic, processed probability
   (or pass/fail result), and evaluation.
2. `-table_wide` adds `Weight%` and `Score`. Weight is the result's share of the
   total weight of all results at that checkpoint, including filtered-out rows.
3. `-table_scoring` shows compact raw statistics, `Sus`, `WMod`, `Scor`, and the
   evaluation. `Sus` is signed suspicion converted to base 10 with the upstream
   display sign; positive values indicate the lower probability tail and negative
   values the upper tail. `WMod = -log10(normalized weight)` and
   `Scor = max(0, abs(Sus) - WMod)`, calculated before display rounding.

```sh
.work/install/bin/RNG_test sfc64 -seed 0 -a -table_wide -tlmax 1M
.work/install/bin/RNG_test sfc64 -seed 0 -a -table_scoring -tlmax 1M
```

The table choice changes presentation. Filtering, result ordering, evaluation,
and failure stopping use the same calculations in every layout.
`--full-precision` appends the existing round-trip raw, probability, and signed
binary suspicion values to any layout. Those signed suspicion values have the
opposite sign and a different scale from the scoring table's `Sus` column.

Formatting follows the original, including its compact rounding, score saturation
markers, and `???` weight modifier when normalized weight is at most `1e-10`.
The upstream `-table_alternative` is unfinished: ordinary numerical rows have a
blank p-value column. That option remains explicitly unsupported.

## Experimental metatest summary

`-do_metatest` enables the optional upstream experimental summary after each
checkpoint's result rows. It is disabled by default; `-no_metatest` disables it,
and the last of those options wins. It works with every layout, full precision,
and both arithmetic modes.

```sh
.work/install/bin/RNG_test sfc64 -seed 0 -do_metatest -tlmin 1M -tlmax 1G
```

The summary takes the square root of the sum of squared positive result scores,
using the unrounded `Scor`/`Score` values described above. Only rows selected by
`-a`, `-e` or `-p` contribute, so changing report filtering can change the summary.
Weights are normalized over all results, including omitted rows. Accumulation
uses original result order before the rows are sorted for display.

| Score | Evaluation |
| --- | --- |
| Less than 0.25 | no problems |
| 0.25 to less than 2 | minor blip |
| 2 to less than 4 | major blip |
| 4 to less than 7 | suspicious |
| 7 to less than 10 | very suspicious |
| 10 or greater | extreme ; probably a failure |

The score prints with one decimal place; evaluation uses the unrounded score.
A checkpoint with results but no selected anomalies reports zero. A checkpoint
without any results has no metatest summary. Each checkpoint computes its score
afresh from its current results. Failure stopping continues to depend on the
largest individual score exceeding 8.5, independently of the combined summary.

This is a heuristic score rather than a calibrated combined p-value. The
calculation has no explicit correlation adjustment, and upstream discourages
end-user metatests because correlations and biases in component probabilities
can distort their interpretation. See the
original discussion (`.vendor/PractRand/doc/Tests_overview.txt`) ([source acquisition](reference-source.md)) and
implementation (`.vendor/PractRand/tools/RNG_test.cpp`) ([source acquisition](reference-source.md)).

## Verification

The full and unit test targets compare all three layouts byte-for-byte against
62 fixed cases captured from the unchanged original `print_result` function.
They cover result kinds, both probability tails, non-unit weights, tiny weights,
raw/suspicion/score rounding and saturation, evaluation levels, and long names.
Fixtures and their capture provenance are retained in
[`test/reference-results/report-tables`](../test/reference-results/report-tables/README.md).
Tests only read those captures.

Bounded CLI checks additionally cover the default layout, repeated options,
filter option order, both arithmetic modes, full precision in each layout, and
rejection of the unfinished alternative option.

Metatest checks compare 26 fixed cases with captures from the unchanged original
`show_checkpoint` function. They cover every evaluation transition, multiple
anomalies, weights, both tails, filtering, empty results, low-quality result
kinds, and infinite scores. The retained captures and provenance are in
[`test/reference-results/metatests`](../test/reference-results/metatests/README.md).
CLI checks cover option precedence, all layouts, both arithmetic modes, repeated
checkpoints, and the default disabled behavior; the checkpoint probe verifies
that combined anomalies do not independently trigger failure stopping.
