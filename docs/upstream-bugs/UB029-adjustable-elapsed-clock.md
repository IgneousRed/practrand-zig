# UB029 — Calendar-clock corrections change elapsed time and duration limits

**Status:** Confirmed source-level defect; deterministic synthetic-clock reasoning,
without changing the machine's clock or claiming an observed clock adjustment.

Original 0.96's `RNG_test.cpp` (`.vendor/PractRand/tools/RNG_test.cpp`) ([source acquisition](../reference-source.md))
defines `CPP_2011_SUPPORTED` and reads `std::chrono::system_clock` in `get_time`.
Its elapsed-time calculation also reads `std::time`; both follow the adjustable
calendar clock. Neither is a monotonic elapsed-time source. A manual clock change
or discontinuous clock synchronization can therefore change reported elapsed time
and the firing of duration-based reporting/stopping events.

For a synthetic run starting at calendar second 1000, five elapsed seconds and a
600-second backward correction give both clock differences as -595 seconds.
The fallback comparison in the main loop retains that negative elapsed value.
A 600-second forward correction instead gives 605 seconds and can fire a
60-second limit after only five elapsed seconds. These examples establish the
arithmetic effect; no real clock adjustment or byte-stream run was performed
against the original for this issue.

The rewrite previously used `gettimeofday` and had the same clock-selection
problem. It now uses `CLOCK_MONOTONIC` for elapsed reports and duration events,
and exits with status 1 if that clock cannot be read. See
[D015](../departures-from-upstream.md#d015--monotonic-elapsed-time).

Public disclosure was not searched for this record; the older November 1 search
does not establish this issue's disclosure status.
