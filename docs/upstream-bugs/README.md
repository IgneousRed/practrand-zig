# Known and suspected bugs in original PractRand

This directory is the maintained upstream issue record. Each issue file tracks
one issue, documentation mismatch, or unresolved observation, with
its evidence, reproduction/confirmation status, rewrite handling, and public
disclosure search result. UB004 groups all bad-RNG-to-NaN cases as one issue, retaining their distinct
mechanisms and evidence. Other independent defects remain separate. See [the NaN audit](../nan-audit.md) for cross-issue coverage and controls.

The reference is untouched PractRand 0.96; see [provenance](../reference-source.md)
and [testing](../testing.md). Record user-visible rewrite differences in the
[departure log](../departures-from-upstream.md). Recording an upstream issue does
not authorize changing statistical behavior.

Existing IDs remain stable except for the pre-existing UB020 collision: duration
overflow retains UB020; raw inverse-calibration interpolation is UB021. Letter
suffixes split formerly bundled records while retaining their original group IDs
below. UB022 gives the already-observed FPMulti abort its own record.

[UB050](UB050-seed-width-autodetection.md) records the newly inspected seed-width
autodetection formula. Its latent low-word error is preserved; no current built-in
trigger or public disclosure is claimed.

[UB051](UB051-decimal-length-rounding.md) records reproduced decimal-length
rounding at complete-block boundaries. The rewrite preserves it at the user's request.

[UB052](UB052-seed-width-validation.md) records native seed-CLI widths accepted
outside the range described by original help and enforced by its expression factory. The
rewrite preserves native CLI acceptance at the user's request, including the
original tiny-space stall; the expression-factory range remains unchanged.

[UB053](UB053-binarymult16-signed-overflow.md) records a promoted signed
multiplication in the unchanged `binarymult16` generator. The rewrite defines
the product locally without changing vendor or expected bytes.
[UB054](UB054-entropy-history-exhaustion.md) records the original one-byte
entropy-history stall; the rewrite rejects that configuration.
[UB055](UB055-fibmulmix16-signed-overflow.md) records the fibmulmix16 product
overflow, now defined locally without changing the retained expected bytes.
[UB056](UB056-garthy16-signed-overflow.md) and UB057–UB071 record the broader
built-in arithmetic audit. The non-Ranrot remedies preserve the original byte
fixtures. UB070 records the explicit Ranrot choice: original names preserve the
captured repeating stream with a warning; `_fixed` names define the intended
changing recurrence under D029.

## Search scope

Checked November 1, 2026 using SourceForge's live public REST API, because cached
web pages omitted the newest tickets. Searched all **25 public bug tickets**,
including closed tickets and their discussion comments, and all **76 Open
Discussion topics / 621 posts** returned by the API. Thread requests used a
100-post limit; every forum topic's returned post count matched its declared count.
Searched full downloaded text for issue identifiers, function names, error messages,
CLI options, and symptom variants, then read candidate reports and replies.

Sources: [tracker](https://sourceforge.net/p/pracrand/bugs/),
[complete ticket query](https://sourceforge.net/rest/p/pracrand/bugs/search?q=%2A%3A%2A&limit=100),
[discussion forum](https://sourceforge.net/p/pracrand/discussion/366935/), and
[topic listing](https://sourceforge.net/rest/p/pracrand/discussion/366935/?limit=100).
Per-issue files retain the relevant search terms and direct evidence links. Working
captures are retained locally; these records stand on their own without them.

**Disclosed** means a matching mechanism or reproduction is public. **Symptom
disclosed** means the same user-visible symptom was reported without establishing
the present diagnosis. **Related only** marks a plausible lead that does not
establish the same issue. **No match found** means exactly that; it does not prove
an issue was never disclosed. Private/deleted posts, unindexed attachments and
external correspondence are outside this search. No reports or comments were posted.

## Matching disclosures

| Local issue | SourceForge evidence | Result when checked |
|---|---|---|
| [UB001](UB001-fpf64-checkpoints.md) | [#25](https://sourceforge.net/p/pracrand/bugs/25/), October 27, 2026 | Same FPF/64 checkpoint dependence and sampling-phase cause; open |
| [UB022](UB022-fpmulti-zero-gap-product.md) | [#18](https://sourceforge.net/p/pracrand/bugs/18/), October 7, 2023 | Same FPMulti zero-input abort; open |
| [UB008d](UB008d-file-input-documentation.md) | [2018 comment](https://sourceforge.net/p/pracrand/discussion/366935/thread/3c6e7916/ccdb/9de3/) | Outdated file-input instructions already reported; symptom match |

## Historical NaN reports

The author's [2018 post](https://sourceforge.net/p/pracrand/discussion/366935/thread/3c6e7916/9b4f/)
acknowledges an unidentified test returning NaN and crashing higher-level handling.
A [2019 follow-up](https://sourceforge.net/p/pracrand/discussion/366935/thread/3c6e7916/0a78/)
describes replacing a NaN conversion hang with an error. Neither identifies NS3,
DC7, Gap16 rounding, or the audited empty-histogram cause. These are related history,
not confirmed disclosures of those specific defects.

The [2016 BCFN_FF report](https://sourceforge.net/p/pracrand/discussion/366935/thread/2b43b548/1ba9/)
acknowledges bad frequency p-values but does not identify either audited cause.
An [earlier Birthday suite selection error](https://sourceforge.net/p/pracrand/discussion/366935/thread/6a1eb94c/)
concerns Rep16 in 0.94, not the present 0.96 Birthday64/help mismatch. Such distinctions
are retained in the individual records instead of treating similar names as proof.

## Issue index

| ID | Issue | SourceForge search result |
|---|---|---|
| [UB001](UB001-fpf64-checkpoints.md) | FPF/64 depends on the first checkpoint/input call | Disclosed |
| [UB002](UB002-removed-rng-catalog.md) | Recommended RNG catalog contains removed generators | Related only |
| [UB003](UB003-entropy-wrapper-bounds.md) | Entropy-wrapper factory parses both length bounds from one argument | No match found |
| [UB004](UB004-bad-rng-nan.md) | Bad RNG input produces NaN instead of a failing result | Related only |
| [UB006](UB006-gap16-rarity-nan.md) | Folded Gap-16:C: reference NaN, rewrite finite | Related only |
| [UB007](UB007-entropy-pool-crash.md) | Entropy-pool target can crash in the reference build | No match found |
| [UB008a](UB008a-threshold-help.md) | Help claims zero or negative thresholds can disable filtering | No match found |
| [UB008b](UB008b-report-interval-help.md) | Help gives the wrong default reporting interval | No match found |
| [UB008c](UB008c-birthday-suite-help.md) | Birthday suite help does not match the selected test | Related only |
| [UB008d](UB008d-file-input-documentation.md) | Documentation omits implemented direct file input | Symptom disclosed |
| [UB008e](UB008e-entropy-bound-message.md) | Entropy-wrapper range diagnostic excludes a permitted endpoint | No match found |
| [UB008f](UB008f-alternative-table.md) | Alternative table flag exposes an unfinished formatter | No match found |
| [UB009](UB009-error-exit-status.md) | Error exit statuses can report success for failed requests | No match found |
| [UB010](UB010-stdin-classification-seed.md) | Stdin seed labels do not fix randomized classification | No match found |
| [UB011](UB011-fpf-nominal-sample-count.md) | FPF long-stride nominal sample count appears one below counted windows | Related only |
| [UB012a](UB012a-filter-rate-truncation.md) | NearSeq3 truncates the CDF-derived filter rate | No match found |
| [UB012b](UB012b-core-score-filter-range.md) | NearSeq3 core scoring and normalization use different filter ranges | No match found |
| [UB012c](UB012c-combined-score-transform.md) | NearSeq3 combined raw and processed scores use different transform order | No match found |
| [UB012d](UB012d-threshold-trigger-sample.md) | NearSeq3 inserts the triggering sample without rechecking the new threshold | No match found |
| [UB012e](UB012e-threshold-inclusivity.md) | NearSeq3 size paths disagree on threshold inclusivity | No match found |
| [UB012f](UB012f-threshold-exhaustion.md) | NearSeq3 can access a negative CDF index before rejecting threshold exhaustion | No match found |
| [UB013](UB013-pat5-sentinel-total.md) | Pat5 global match total includes uninitialized-pattern sentinels | No match found |
| [UB014](UB014-pat5-batch-tail.md) | Pat5 omits tail centers on every input call | No match found |
| [UB015a](UB015a-empty-g-test.md) | Empty histograms can reach G-test scoring | Related only |
| [UB015b](UB015b-degenerate-rarity.md) | Rarity scoring divides by zero for empty or zero-variance models | No match found |
| [UB015d](UB015d-bcfn-ff-gamma-range.md) | BCFN_FF ramp input aborts with invalid gamma parameters | Related only |
| [UB016](UB016-coup32-incomplete-mean.md) | Coup32 reports a mean before completing a set | No match found |
| [UB017c](UB017c-poisson-zero-endpoint.md) | Poisson PMF returns NaN for the degenerate zero endpoint | No match found |
| [UB017d](UB017d-log-factorial-wrap.md) | Log-factorial wraps its maximum unsigned argument | No match found |
| [UB017e](UB017e-unused-upper-gamma-overflow.md) | Unused upper incomplete gamma has a finite-input NaN path | No match found |
| [UB017f](UB017f-formatter-endpoint-nan.md) | CLI formatting evaluates an unused NaN at endpoint p-values | No match found |
| [UB018a](UB018a-sampleset-variance.md) | SampleSet standard deviation can produce NaN from identical finite samples | No match found |
| [UB018b](UB018b-sampleset-percentile.md) | SampleSet percentile interpolation overflows at an exact finite sample | No match found |
| [UB019](UB019-brank-inverse-endpoint.md) | BRank inverse calibration produces NaN at p-value zero | No match found |
| [UB020](UB020-duration-overflow.md) | Duration unit conversion can overflow to an infinite deadline | No match found |
| [UB021](UB021-inverse-calibration-interpolation.md) | Raw inverse-calibration interpolation uses the wrong difference | No match found |
| [UB022](UB022-fpmulti-zero-gap-product.md) | FPMulti aborts when its gap product becomes zero | Disclosed |
| [UB023](UB023-normal-cdf-erf-cancellation.md) | Error-function cancellation corrupts normal and chi-square CDFs | Not searched |
| [UB024](UB024-g-test-cancellation.md) | G-test subtraction loses small statistics for large nonempty counts | Not searched |
| [UB025](UB025-gapuni-tail-cancellation.md) | GapUniversal3 multiple-comparison adjustment loses tiny probabilities | Not searched |
| [UB026](UB026-upper-gamma-integer-formula.md) | Unused integer upper-gamma branch has an incorrect formula | Not searched |
| [UB027](UB027-normal-logpdf-overflow.md) | Normal log-density overflows an avoidable intermediate | Not searched |
| [UB028](UB028-poisson-peak-cancellation.md) | Poisson peak evaluation loses precision for large lambda | Not searched |
| [UB029](UB029-adjustable-elapsed-clock.md) | Calendar-clock corrections change elapsed time and duration limits | Not searched |
| [UB030](UB030-unchecked-output-errors.md) | Failed report writes can still be treated as success | Not searched |
| [UB031](UB031-unguarded-x86-headers.md) | Unconditional x86 headers prevent native ARM tool builds | Not searched |
| [UB032](UB032-pvalue-center-cancellation.md) | P-value-to-suspicion cancellation near one half | Not searched (November 13, 2026) |
| [UB033](UB033-normal-score-center-cancellation.md) | Normal suspicion loses its first-order term near zero | Not searched (November 13, 2026) |
| [UB034](UB034-brank-tail-roundtrip.md) | BRank rounds finite exponential tails to endpoints | Not searched (November 13, 2026) |
| [UB035](UB035-permutation-probability-accumulation.md) | Permutation probability enumeration accumulates rounding error | Not searched (November 13, 2026) |
| [UB036](UB036-birthday-tail-cancellation.md) | Birthday large-count log-tail cancellation | Not searched (November 13, 2026) |
| [UB037](UB037-hamming-subnormal-cutoff.md) | Hamming probabilities discard representable subnormals | Not searched (November 13, 2026) |
| [UB038](UB038-fpf-overall-cancellation.md) | FPF overall nominal G-test cancellation | Not searched (November 13, 2026) |
| [UB039](UB039-gap-bin-cancellation.md) | Gap bin probabilities subtract nearby powers | Not searched (November 13, 2026) |
| [UB040](UB040-birthday-integer-residual.md) | Birthday rounds away small integer residuals | Not searched (November 13, 2026) |
| [UB041](UB041-rarity-count-cancellation.md) | Rarity multiplies rounded centered weights by large counts | Not searched (November 13, 2026) |
| [UB042](UB042-score-accumulation.md) | Score accumulation discards low addends; practical effect not isolated | Not searched (November 13, 2026) |
| [UB043](UB043-calibration-index-roundtrip.md) | Calibration loses local fraction bits in its index round trip | Not searched (November 13, 2026) |
| [UB044](UB044-hamming-log-tail-underflow.md) | Hamming scores take logarithms after CDF underflow | Not searched (November 13, 2026) |
| [UB045](UB045-report-tail-filter-cancellation.md) | Report selection loses precision around tail thresholds | Not searched (November 13, 2026) |
| [UB046](UB046-birthday-midpoint-tail-cancellation.md) | Birthday midpoint CDF loses precision in its upper tail | Not searched (November 13, 2026) |
| [UB047](UB047-gap-startup-normalization.md) | Gap startup normalization cancels retained mass | Not searched (November 13, 2026) |
| [UB048](UB048-bcfn-probability-folding.md) | BCFN folds rounded probabilities | Not searched (November 13, 2026) |
| [UB049](UB049-nearseq-conditional-underflow.md) | NearSeq conditional probabilities overflow or underflow | Not searched (November 13, 2026) |
| [UB051](UB051-decimal-length-rounding.md) | Decimal length accumulation can lose one complete test block | Not searched (November 21, 2026) |
| [UB052](UB052-seed-width-validation.md) | Native seed CLI and expression factory enforce different widths | Not searched (November 21, 2026) |
| [UB053](UB053-binarymult16-signed-overflow.md) | binarymult16 multiplication overflows promoted signed int | Not searched (November 21, 2026) |
| [UB054](UB054-entropy-history-exhaustion.md) | One-byte entropy history exhausts its message space | Not searched (November 21, 2026) |
| [UB055](UB055-fibmulmix16-signed-overflow.md) | fibmulmix16 multiplication overflows promoted signed int | Not searched (November 21, 2026) |
| [UB056](UB056-garthy16-signed-overflow.md) | garthy16 multiplication overflows promoted signed int | Not searched (November 22, 2026) |
| [UB057](UB057-mrc16-signed-overflow.md) | Raw mrc16 product | Not searched (November 22, 2026) |
| [UB058](UB058-mrsf16-signed-overflow.md) | mrsf16 product | Not searched (November 22, 2026) |
| [UB059](UB059-mulcrax16-signed-overflow.md) | mulcrax16 product | Not searched (November 22, 2026) |
| [UB060](UB060-mulcrx16-signed-overflow.md) | mulcrx16 product before rotation | Not searched (November 22, 2026) |
| [UB061](UB061-multish4x16-signed-overflow.md) | multish4x16 product | Not searched (November 22, 2026) |
| [UB062a](UB062a-mwlac-vara-signed-overflow.md) | mwlac_varA product | Not searched (November 22, 2026) |
| [UB062b](UB062b-mwlac-varb-signed-overflow.md) | mwlac_varB product | Not searched (November 22, 2026) |
| [UB062c](UB062c-mwlac-varc-signed-overflow.md) | mwlac_varC product | Not searched (November 22, 2026) |
| [UB062d](UB062d-mwlac-vard-signed-overflow.md) | mwlac_varD product | Not searched (November 22, 2026) |
| [UB062e](UB062e-mwlac-vare-signed-overflow.md) | mwlac_varE product | Not searched (November 22, 2026) |
| [UB062f](UB062f-mwlac-varf-signed-overflow.md) | mwlac_varF product | Not searched (November 22, 2026) |
| [UB063](UB063-mwrca16-signed-overflow.md) | mwrca16 product | Not searched (November 22, 2026) |
| [UB064](UB064-mwrcc16-signed-overflow.md) | mwrcc16 product | Not searched (November 22, 2026) |
| [UB065](UB065-mwrcca16-signed-overflow.md) | mwrcca16 product | Not searched (November 22, 2026) |
| [UB066](UB066-old-mwlac16-signed-overflow.md) | old_mwlac16 product | Not searched (November 22, 2026) |
| [UB067](UB067-vf16-signed-overflow.md) | VeryFast16 product | Not searched (November 22, 2026) |
| [UB068](UB068-gjishc-invalid-rotation.md) | gjishC zero rotation | Not searched (November 22, 2026) |
| [UB069](UB069-varrotc-invalid-rotation.md) | varrotC zero rotation | Not searched (November 22, 2026) |
| [UB070](UB070-ranrot-zero-rotation.md) | Ranrot zero rotations invalidate the refill | Not searched (November 22, 2026) |
| [UB071](UB071-sfc-alt8-invalid-rotation.md) | SFC alternative8 rotation exceeds word width | Not searched (November 22, 2026) |

## Legacy group IDs

These former aggregate IDs now lead to separate issue files.

### UB008

Documentation/help mismatches: [UB008a](UB008a-threshold-help.md), [UB008b](UB008b-report-interval-help.md), [UB008c](UB008c-birthday-suite-help.md), [UB008d](UB008d-file-input-documentation.md), [UB008e](UB008e-entropy-bound-message.md), [UB008f](UB008f-alternative-table.md).

### UB012

NearSeq3 scoring and threshold questions: [UB012a](UB012a-filter-rate-truncation.md), [UB012b](UB012b-core-score-filter-range.md), [UB012c](UB012c-combined-score-transform.md), [UB012d](UB012d-threshold-trigger-sample.md), [UB012e](UB012e-threshold-inclusivity.md), [UB012f](UB012f-threshold-exhaustion.md).

### UB015

Empty/degenerate statistical states and BCFN_FF aborts: [UB015a](UB015a-empty-g-test.md), [UB015b](UB015b-degenerate-rarity.md), [UB004](UB004-bad-rng-nan.md#gapuniversal3-guarded-internal-nan), [UB015d](UB015d-bcfn-ff-gamma-range.md).

### UB017

Shared scalar math and formatting: [UB004](UB004-bad-rng-nan.md#shared-chi-square-infinity-conversion), [UB004](UB004-bad-rng-nan.md#shared-normal-infinity-conversion), [UB017c](UB017c-poisson-zero-endpoint.md), [UB017d](UB017d-log-factorial-wrap.md), [UB017e](UB017e-unused-upper-gamma-overflow.md), [UB017f](UB017f-formatter-endpoint-nan.md).

### UB018

SampleSet numerical failures: [UB018a](UB018a-sampleset-variance.md), [UB018b](UB018b-sampleset-percentile.md).

UB005, UB017a, UB017b and UB015c are consolidated into [UB004](UB004-bad-rng-nan.md);
the bad-input stream cases formerly in UB015a are there as well.
