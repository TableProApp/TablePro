# Combined resource validation

Status: historical local integration of [PR 1529](https://github.com/cozyGarage/BookiE/pull/1529) and [PR 1530](https://github.com/cozyGarage/BookiE/pull/1530), not Forgejo acceptance. [Inputs](inputs.json) pin the actual merged source heads. The two fixes change separate editor lifecycle and result presentation paths. Only additive documentation-index conflicts required resolution; both entries were preserved.

The [editor investigation](../local-resource-profiling-2026-10-23/README.md) and [stream investigation](../stream-page-realization-2026-10-23/README.md) own their separate measurements. This record owns checks performed with both changes present. Do not treat separate-head results as combined acceptance.

The saved-script probe now permits a UTF-8 workload with `TABLEPRO_PROFILE_UTF8=1`. Generated content is bounded by encoded byte count; accessibility character-count checks remain based on Unicode characters. This is workspace restoration backed by an actual file, not file-chooser acceptance. The completed local checks and optimized workload results are recorded below.


## Local validation and measurements

[Validation](validation.json) passed full preflight with 2073 non-GTK unit and 2086 sandbox cases plus Redis cancellation, app all-target Clippy, 791 app tests and all 153 isolated GTK scenarios. [Build identity](build.json) pins the immutable optimized executable and relevant source hashes. No competing compilation ran during the measured workloads.

Two [one-million-row cycles](stream-1m.json) completed in 2.261 and 2.262 seconds. Three [two-million-row cycles](stream-2m.json) completed in 4.179, 4.168 and 4.177 seconds, with retained-page navigation in both directions and first-row checks. These runs verify both fixes together; they do not replace Forgejo acceptance.

The first [UTF-8 restore/early-close run](utf8-early-close.json) loaded 8388600 bytes in 6.762 seconds. RSS was 304928 KiB when loaded and 304560 KiB ten seconds after tab disappearance. The original file stayed unchanged, and a new editor completed a fresh query after the observation window.

A matched fixture pair added explicit observed close latency: [candidate](utf8-close-latency.json) versus the [unchanged baseline](utf8-close-baseline.json). Load times were 6.672 versus 6.711 seconds; observed tab disappearance took 1.585 versus 3.895 seconds. Ten seconds later, RSS was 304196 versus 420624 KiB. Candidate RSS was 304508 KiB when loaded, whereas baseline RSS was 270096 KiB: the candidate avoided the baseline's roughly 147 MiB post-load growth rather than simply starting with a smaller footprint. These are single paired observations, not a variance estimate. Recorded CPU after loading increased by 5.49 seconds on the candidate and 3.90 seconds on the baseline; faster visible close and lower settled RSS do not imply lower CPU in every phase.

## Remaining scope

File-chooser loading, oversized-file refusal, a dedicated cold-start resource measurement, installed runtime-failure cases and empty welcome-view response remain unverified by this record. Native Wayland appearance also remains unchecked. The [stream investigation](../stream-page-realization-2026-10-23/README.md) records exact full CSV output and the unresolved clipboard interaction. [Issue 1531](https://github.com/cozyGarage/BookiE/issues/1531) owns the multiline preview-height defect. Both constituent fixes have since merged as #1529 and #1530, and the multiline preview repair merged as #1533. This record still proves only its pinned source, not the current Linux head. No permanent memory plateau or absence of other leaks is claimed.
