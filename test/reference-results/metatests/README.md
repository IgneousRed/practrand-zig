# Original experimental metatest fixtures

Captured on November 21, 2026 from unchanged **PractRand 0.96** using
[`metatest_reference.cpp`](../../metatest_reference.cpp). The driver includes
`tools/RNG_test.cpp` with its entry point renamed and calls `show_checkpoint`
with a test manager supplying fixed result rows. It does not reimplement the
score or evaluation. Reference release provenance, URL, archive checksum, and
license are recorded in [vendor provenance](../../../docs/reference-source.md).

[`metatest_cases.tsv`](../../metatest_cases.tsv) contains 26 cases. Each line has
the case name, smart-filter flag, threshold, and two triples of result kind,
processed value, and unnormalized weight. A `none` kind omits that result. Raw
statistics are zero. The first result is named `z-result`, the second `a-result`,
so rewrite presentation sorting reverses their order. Cases cover both sides of
each evaluation boundary, combined anomalies, weight normalization, lower/upper
tails, smart and direct filtering, no selected rows, no results, approximate
probabilities/suspicions, retained extreme suspicion, endpoint infinities, and
pass/fail results.

The capture used Apple Clang targeting x86-64 macOS through the documented
reference builder. Explicit capture commands are:

```sh
python3 -B tools/build_reference.py --driver test/metatest_reference.cpp \
  --tools --output .work/metatest/reference-metatest
.work/metatest/reference-metatest < test/metatest_cases.tsv > .work/metatest/original-checkpoints.txt
```

The retained `summaries.txt` contains the `case=` and `  metatest score:` lines
from that output, in source order, with all other lines removed. The empty case
has no summary. Evaluation uses unrounded scores, so adjacent boundary cases can
have the same printed score and different labels. Endpoint probabilities produce
the original `inf` score. Ordinary tests only read these captures and must never
regenerate them. The test probe also checks that an extreme combined score with
individual scores below the failure threshold does not trigger failure stopping.

SHA-256 at capture:

```text
0dc6b33bec8f54fb18e2ad7ca09d9997b46fccf29b6c0ea074dd79f61849bb92  vendor/PractRand/tools/RNG_test.cpp
d0474581c3979fd723f9727766a1d4a004dbf1fedfe289f7fb01e3da7692f30d  test/metatest_reference.cpp
6a85cc73fa7b82a85dac99088224b2c7040d746fb0f47571c7d9122402923d3b  test/metatest_cases.tsv
a794c88b6af2c248309164191a4f77fa171f73b57526bd93113c11e443e59393  test/reference-results/metatests/summaries.txt
```
