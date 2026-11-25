# UB042 — Score accumulation discards low addends

**Status:** Source-confirmed uncompensated accumulation; its effect on original
full-stream results has not been isolated.

NearSeq3's model moments and signed scores in
`.vendor/PractRand/src/tests_other.cpp:5518` onward, and decayed histories at
line 5883 onward, use ordinary double sums. BRank's running score uses ordinary
addition at `.vendor/PractRand/src/tests_core.cpp:3824`. Repeated addition and
rescaling can discard low terms before later cancellation makes them relevant.

Improved mode uses compensated binary64 accumulation for these paths, carrying
product rounding through history rescaling. Reference NearSeq3 retains ordinary
operations in the original order. BRank keeps its original high running sum and
an additional low component; reference scoring reads the original high sum only.
No sample-selection, matrix-rank score, threshold or history-decay rule changes.

`src/statistics.zig` checks an exact product/scaling residual and legitimate
infinite-tail handling. `src/near_seq.zig` checks model moments against independent
binomial/Decimal controls. Existing serial/parallel tests include BRank's low
state. These controls validate the rewrite's arithmetic; they do not establish a
new upstream stream failure or the size of practical calibration effects.
Vendored source is unchanged. Public disclosure was not searched for this
November 13, 2026 record.
