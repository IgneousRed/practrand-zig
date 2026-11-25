# Original report-format fixtures

Captured on November 21, 2026 from the unchanged **PractRand 0.96**
`print_result` function in `tools/RNG_test.cpp`, using
[`report_reference.cpp`](../../report_reference.cpp). The driver includes the
original CLI with its entry point renamed and calls its formatter directly.
It does not implement a substitute formatter. The source release, URL, archive
SHA-256 and license are recorded in [vendor provenance](../../../docs/reference-source.md).

The fixed input rows are [`report_cases.tsv`](../../report_cases.tsv): name,
result kind, raw statistic, processed value and normalized weight. Each output
has a header and row for every input. The 62 inputs exercise result kinds,
probability tails, weights, rounding/saturation boundaries and evaluation levels.
The probability samples avoid exact decimal-significand truncation boundaries,
where the existing formatter can expose platform math rounding differences.
Only the finished narrow (0), wide (1), and scoring (3) layouts are captured.

The capture was built with Apple Clang for x86-64 macOS using the documented
reference builder. Reference executables and intermediate captures are retained locally. These fixtures are authoritative inputs; ordinary tests
read them and must never regenerate them.

Explicit reference build:

```sh
python3 -B tools/build_reference.py --driver test/report_reference.cpp \
  --tools --output .work/report-tables/reference-report
.work/report-tables/reference-report 0 < test/report_cases.tsv > .work/report-tables/narrow.txt
.work/report-tables/reference-report 1 < test/report_cases.tsv > .work/report-tables/wide.txt
.work/report-tables/reference-report 3 < test/report_cases.tsv > .work/report-tables/scoring.txt
```

A reviewed initial capture supplied the retained `.txt` files here.
The test uses the rewrite's real checkpoint renderer with an unprinted control
row to make each supplied weight already normalized; it compares headers and
named fixture rows byte-for-byte. CLI integration is checked separately.

SHA-256 at capture:

```text
0dc6b33bec8f54fb18e2ad7ca09d9997b46fccf29b6c0ea074dd79f61849bb92  vendor/PractRand/tools/RNG_test.cpp
e39c1221890340c1a72a499b44f4f7c487186348603900217e9fd562efee39ba  test/report_reference.cpp
4044c2f69bf9bad177cb109b97f672ae2e2868e9e119f2472c3f3b2a243f4779  test/report_cases.tsv
497a9846ffd675f5a69c45a0e21a526d2d6c8b2b4e631cd778d0ed206135bc31  test/reference-results/report-tables/narrow.txt
20f77fa36770658051b8d146eb25bb471a39977f0279e5d3cf1816f49683889b  test/reference-results/report-tables/wide.txt
6dc3a37647166cf6368255fbe86fe2a51f40ac9182ea3876611047376c95113a  test/reference-results/report-tables/scoring.txt
```
