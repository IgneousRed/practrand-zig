# UB018a — SampleSet standard deviation can produce NaN from identical finite samples

**Status:** Reproduced with finite inputs; calibration/research helper, not a
new byte-stream battery failure.

`get_stddev` in `test_helpers.h` evaluates
`sqrt(mean_of_squares - mean * mean)` without stabilizing or clamping the
variance. Adding 100 identical values of `1e12`, `1e16`, or `1e100` yields NaN in
the reference build through cancellation and a negative rounded variance. Very
large finite values also overflow the moments, producing infinity minus infinity.
The true standard deviation of identical finite values is zero.

The retained scalar probe reproduces this behavior. These helpers are not implemented as part of the rewrite CLI.

## SourceForge disclosure

**Checked:** November 1, 2026. **Result:** No match found.

No matching PractRand helper disclosure found. The [March 2019 comment](https://sourceforge.net/p/pracrand/discussion/366935/thread/3c6e7916/0a78/5b81/) describes the commenter’s own standard-deviation code, not PractRand’s SampleSet.

Search terms: `SampleSet, get_stddev, negative variance, mean_of_squares`. See [search scope](README.md#search-scope) for coverage and limits.
