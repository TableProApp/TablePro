# Stream-cache byte budget, October 22

[#1032](https://github.com/cozyGarage/BookiE/issues/1032) owns the broader resource investigation. The maintainer approved a byte budget alongside the four-page cap. The recorded handoff allows UX to expose core's existing row-size estimate instead of duplicating value and JSON accounting in the UI.

Two cache regressions failed on the original implementation: three 24 MiB text pages remained retained, and a 65 MiB page remained after replacement by a small newer page. The corrected cache records each page estimate once and evicts oldest pages until both limits are met, while always keeping the newest page. Eviction must release the cache's strong reference; full values and received-row/page counts remain unchanged. A single oversized newest page is deliberately retained and remains a documented exception.

Core's read-only estimated_row_bytes method sums the existing row_size accounting. A separate unit test derives the expected size from owned string capacity, Value storage and row-vector containers. The estimate excludes column metadata and allocator overhead; no claim of total process memory follows from it. Pinned results and overlapping snapshots can continue owning evicted pages.

All nine focused cache cases passed after the fix; the core owned-capacity/container estimate test passed independently. Full preflight, all 103 isolated GTK cases and app all-target Clippy passed. All 715 non-ignored app unit tests passed; 141 tests were ignored in that general selector, with the registered GTK subset exercised separately. Real-query CPU/RSS profiling and Forgejo acceptance remain pending. This cache slice does not complete the broader pin/export/teardown acceptance in #1032 and does not establish that GTK or allocator-retained memory is released.

## Optimized paired comparison

The [manifest](manifest.json) pins an integration baseline containing the corrected PostgreSQL metadata fix and frame-deferred grids, then a candidate differing in runtime code only by the byte budget and core estimator. The [comparison](comparison.json) records six successful query/replacement/close cycles per binary, each with 50,000 rows and an 8,193-byte payload, PostgreSQL 17.11, private D-Bus/Xvfb and Cairo. Candidate ran first. No local build or test ran during either capture. Both exited 0 without safety abort; perf exited -2, so CPU figures use process accounting.

Peak RSS fell from 499.44 to 361.05 MiB (27.71% lower), but CPU rose from 54.12 to 70.74 seconds (30.71% higher). Query completion was about 7.0–7.4 seconds for baseline and 9.8–10.1 seconds for candidate. All baseline ranges were 30001–50000 and all candidate ranges were 45001–50000, with all 50,000 rows received.

This exposes a CPU trade-off, not complete performance acceptance. PR #1322 is draft pending investigation. Perf samples attribute most CPU to HarfBuzz, Pango and GLib in both runs; this does not yet prove which UI transition caused the additional work. The owned PostgreSQL fixture was stopped after the comparison. Repeated order reversal, allocation attribution and a correction to the extra rendering work remain pending.
