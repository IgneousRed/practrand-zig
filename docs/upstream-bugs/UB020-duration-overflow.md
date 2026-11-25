# UB020 — Duration unit conversion can overflow to an infinite deadline

**Status:** Confirmed in the isolated original parser; deadline handling is
established by source inspection. No full battery was run for this malformed input.

Original `tools/RNG_test.cpp`'s `interpret_length` parses a decimal and multiplies
it by the seconds/minutes/hours/days scale without a finiteness check. Pass the
string consisting of `1`, 308 zeros, and `d`: the decimal value is finite, but
conversion returns negative infinity, the tool's representation of a time limit.
An isolated compilation of that unchanged function prints `seconds=inf,
finite=0`. The second argument is `true`, selecting ordinary byte-stream mode.

The `-tlmax` handler rejects only nonnegative lengths below one block. It accepts
this negative infinity and stores positive infinity in `show_times`. A finite
elapsed time cannot reach the deadline, so `-tlmaxonly` cannot stop at that
requested limit. This is an input-validation failure, separate from the
statistical NaNs recorded in [the audit](../nan-audit.md).

The rewrite rejects a non-finite result after unit conversion, before battery
initialization or stdin reads. This extends its existing strict invalid-length
validation; see [D004](../departures-from-upstream.md#d004--invalid-and-unsupported-requests-fail-with-status-1).
Minute/hour/day overflow probes fail with `InvalidLength`; finite duration and
byte-length parsing is retained.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching public disclosure found in the searched SourceForge tracker and discussion text. This is a search result, not proof that the issue was never disclosed.

Search terms: `interpret_length, duration unit overflow, -tlmax, infinite deadline`. See [search scope](README.md#search-scope) for coverage and limits.
