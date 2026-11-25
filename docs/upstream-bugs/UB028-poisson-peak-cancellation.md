# UB028 — Poisson peak evaluation loses precision for large lambda

**Status:** Original-source scalar precision observation; no demonstrated stream failure.

`math_poisson_pmf(1e9, 1000000000)` returns about 1.2615668511597622e-5.
A peak-specific Stirling expansion gives 1.2615662609049518e-5, a relative
difference of approximately 4.7e-7. At lambda=1e6 the difference is about 6.8e-10.
The comparison uses `exp(-log(2*pi*n)/2 - 1/(12*n) + 1/(360*n^3))`;
its omitted asymptotic terms are negligible at these n. This control is not
an exact reference for small n; the retained probe starts at n=1000.

The expression subtracts large nearly equal log-factorial and log-power terms.
A deviance-centered log-PMF with a Stirling correction or a recurrence anchored
near the mode can avoid this loss without changing floating types. Summing the
needed tail directly also avoids CDF complementation loss.

Active Poisson callers exist in BirthdaySystematic2 and experimental Birthday
variants. The main BirthdaySystematic2 path calls the PMF only for lambda<=64;
this large-lambda example therefore does not establish that its reports are
inaccurate. See [audit](../precision-audit.md) and the retained
[probe](../../test/upstream_precision.cpp). No production behavior changed.
Public disclosure was not searched for this finding.
