# Stream page construction, October 22

Owner: [#1306](https://github.com/cozyGarage/BookiE/issues/1306). Source base: `bf036c8dc`.

## Reproduction

A stream page builds a grid synchronously when its holder maps. Mapping and removing that holder before a rendered frame still constructs its grid. An isolated GTK regression verifies that sequence and fails on the existing implementation. Live streaming removes old notebook pages; this can briefly map a retained page that is soon removed.

The proposed repair defers construction to a widget-owned frame callback, with one pending callback per holder. The callback takes the build closure once. It does not capture the holder or use a global idle queue. The regression passes, including a weak-reference assertion that dropping the retired holder releases its result. All 104 registered GTK tests passed after selected-page tests were changed to await the observable grid on its frame while preserving grid identity assertions. Full preflight and application all-target Clippy also passed.

## CPU evidence

The normal-width 0.2.0 PostgreSQL capture in the [release evidence](../release-0.2.0-2026-10-21/README.md) resolves using the matching Arch debug package, build ID `3bcdc9f0005231cddcb27d6529c570cc27b509ee`. Inclusive samples place about 19.98% in stream-page map callbacks and 23.54% in live-stream updates. These paths overlap and the percentages must not be added. They do not quantify the proposed fix's benefit.

## Combined preceding fixes

The optimized aggregate #1305 build (`07b85c9a5`, binary SHA-256 `a451835f303d76310a0394057ee9e0cd6092e9f24ea2bfb35a37a6cb9d545675`) completed 10,000-, 100,000- and 1,000,000-row PostgreSQL queries with a successful terminal status and no schema error. The million-row view retained rows 980,001–1,000,000 and reported completion in 16,265 ms. After replacement and close, RSS was about 218.5 MiB.

The wide-value case subsequently lost its accessibility root. The harness exited 1 after 60.214 seconds, with no sampler safety abort. That case and the remainder of the six-case series are not qualified. A concurrent test build also prevents a controlled CPU comparison. This partial capture proves the observed completion fixes for the first three cases, not a resource improvement or crash diagnosis.

Raw captures remain under the dated local release-artifact directory, including `profiles/postgres-load-fixed-train`. Native visual acceptance, optimized before/after comparison and Forgejo acceptance of the frame repair remain pending.

## Optimized comparison

The baseline binary above was compared with `bfe4c159d` (frame repair plus the same preceding fixes), SHA-256 `876dcf853025d7f5cea6f5ba98196d78b4cbceab7be8f6a457c7c9289cd254ed`. Both used the workspace release profile, PostgreSQL 17.11, a private D-Bus session, 1280×1024 Xvfb, Cairo and perf sampling. No concurrent build or local test was running. Each process performed three cycles of the following query, followed by replacement with `SELECT 1` and closing the editor:

```sql
SELECT g AS resource_probe, repeat('x',128) AS payload
FROM generate_series(1,1000000) g;
```

All six queries reported successful completion and retained rows 980,001–1,000,000. [Measurements](comparison.json) include process samples summarized at each phase.

| Three-cycle series | Baseline | Frame repair |
| --- | ---: | ---: |
| Process CPU seconds | 54.08 | 48.97 |
| Total elapsed seconds | 77.229 | 71.915 |
| Peak RSS, MiB | 226.59 | 222.95 |
| Per-query observed CPU seconds | 16.67 / 17.28 / 17.59 | 15.10 / 15.47 / 15.92 |

The observed CPU reduction is approximately 9.4%. Total duration includes connection setup, controlled pauses, accessibility traversal, replacement and close. This is one baseline-first comparison, not a statistical benchmark or a native Wayland result. Perf returned -2 after stopping the baseline capture and 0 for the repaired capture; process CPU totals come from `/proc` sampling rather than profiler exit status. The fixture was stopped afterward.

An earlier comparison attempt connected before PostgreSQL finished initialization and failed before running the workload. It is excluded; the accepted pair ran after an explicit readiness check. After integrating the preceding fixes, the combined 105-test GTK suite and full preflight passed. Longer runs, reversed run order, wide-value behavior and exact-head Forgejo acceptance remain open.

## Repeated wide-value observations

A follow-up on the same repaired binary completed six query/replacement/close cycles with 50,000 rows and 8,193-byte synthetic text values per row. Every query reported success, ten pages received and retained rows 30,001–50,000. The [measurement record](wide-cycles.json) includes terminal labels and phase samples. Peak sampled RSS was 481.99 MiB. After-close RSS was 468.22, 481.03, 481.21, 481.39, 481.99 and 475.87 MiB. During the final 15.004-second idle interval, measured process CPU increased by 0.0 seconds.

This short series did not show sustained growth, but the retained process footprint remains substantial. RSS alone cannot distinguish live allocations from allocator retention; this does not establish leak freedom or explain the retained memory. The earlier failed wide-value capture remains excluded. The follow-up used a profiling-only lookup that returns on the first existing application identity match instead of collecting names from the entire accessibility tree. That is a harness difference, not a demonstrated fix for the earlier accessibility failure. The fixture was stopped after collection.

## Live heap versus resident memory

A separate heaptrack capture completed three wide-value query/replacement/close cycles and exited normally through `win.quit` (wrapper exit 0). No safety abort or forced termination occurred. Heaptrack reported 368.26 MB peak allocated heap, 571.96 MB peak RSS including instrumentation overhead, and 43.57 MB outstanding at process exit. The outstanding total includes runtime/library allocations and is not a demonstrated leak.

Approximate phase alignment of the heaptrack Massif output with process samples gives:

| Phase | Tracked live heap, MiB | RSS including instrumentation, MiB |
| --- | ---: | ---: |
| connected-idle | 42.77 | 232.92 |
| cycle-1-50000rows-8193bytes-after-close | 41.92 | 498.31 |
| cycle-2-50000rows-8193bytes-after-close | 42.57 | 539.30 |
| cycle-3-50000rows-8193bytes-after-close | 43.14 | 540.33 |

The [summary](wide-heap-summary.json) records source identity, tool totals and alignment limits. The live heap returns near its connected-idle level after each close while RSS stays high. This capture therefore does not support a claim that wide query payloads remain live after close. Allocator retention and other non-heap storage need separate attribution. Instrumented CPU/RSS must not be compared directly with the uninstrumented series. This is not whole-application leak-free acceptance. Raw heaptrack, Massif and process traces remain in the dated local artifact directory.

## Arena-count experiment

A child-process-only `MALLOC_ARENA_MAX=2` experiment repeated the same six wide-value cycles and completed successfully. Peak sampled RSS was 480.18 MiB, compared with 481.99 MiB in the earlier default run. After-close samples remained near 480 MiB. This single run did not show a useful reduction, so no application or desktop setting was changed. The [record](arena-experiment.json) preserves configuration and outcomes. The setting is described in the [GNU libc allocation manual](https://sourceware.org/glibc/manual/latest/html_node/Memory-Allocation-Tunables.html); this is experiment provenance, not a recommendation to change defaults.

## Reclaimability diagnostic

A child-only preload probe called `malloc_trim(0)` every five seconds for at most 120 seconds, without changing the profiled application binary. Six 50,000-row queries with 8,193-byte payloads completed, each followed by replacement and tab close. The scenario exited 0 after 109.334 seconds without a safety abort; perf exited -2, so CPU figures come from process accounting. The [summary](trim-experiment.json) records all phase samples.

After-close RSS was 178.12, 181.08, 175.15, 191.30, 192.62 and 194.02 MiB, compared with roughly 468–482 MiB in the earlier default six-cycle capture. Final idle RSS was 193.75 MiB; CPU remained 53.31 seconds across the 15-second idle interval. Peak RSS was 495.63 MiB, so this diagnostic did not reduce peak working data. The existing heap capture independently shows payload allocations released after close. Together these support allocator page retention as a substantial contributor to residual RSS in this workload. They do not prove the absence of other leaks.

The probe is not a production recommendation. Periodic process-wide trimming can affect latency and unrelated allocations. Any product change needs disposal-triggered, bounded scheduling outside the GTK thread, measurements of pause time, and a repeated comparison. No allocator environment or desktop configuration was changed. The owned PostgreSQL container was stopped when the probe ended.

## Corrected dependency refresh

The frame branch now includes #1304's cursor-local PostgreSQL correction rather than the failed shared-casing attempt. Runtime source matches profiling baseline `aebdadea6`; intervening source merges changed only documentation. Full preflight and all 105 isolated GTK tests passed on the refreshed branch. The old failed aggregate #1307 was closed as obsolete. These local checks do not qualify a Forgejo merge gate for the refreshed frame PR.

The branch was refreshed again after #1304 and #1312 merged. Accepted dependency evidence was preserved, the closed #1302 ledger row was removed, and full preflight passed after that integration. The remaining code diff against linux consists of the still-pending toolbar and frame work; no PostgreSQL driver change remains.
