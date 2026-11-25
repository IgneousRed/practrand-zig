# UB027 — Normal log-density overflows an avoidable intermediate

**Status:** Confirmed original-source scalar defect; no active caller found.

`math_normaldist_pdf_log(1.5e154)` returns negative infinity because
`normal*normal * -0.5` squares before scaling. The correct double result remains
representable, approximately -1.125e308. At 1.8e154 the representable result is
approximately -1.62e308, but the original again gives negative infinity.

Compute `-(normal * 0.5) * normal + scale_ln` instead. This changes only operation
order. For still larger arguments, overflow of the actual answer is legitimate.
No active caller was found outside the definition. No rewrite behavior changed.

## Reproduction and disclosure status

See the retained [precision probe](../../test/upstream_precision.cpp) and
[audit commands and scope](../precision-audit.md). Original source is unchanged.
Public disclosure was not searched for this new record; the older November 1
search does not establish this issue’s disclosure status.
