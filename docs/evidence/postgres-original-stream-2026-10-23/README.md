# Original PostgreSQL streaming workload

In-progress qualification for [issue 1272](https://github.com/cozyGarage/BookiE/issues/1272) on Linux `3b6ef5f44`. The fixture recreates the reported ten-column, two-million-row table in an isolated PostgreSQL 16 container and runs `SELECT * FROM big` through the actual editor. Random values use a fixed seed; timestamps reflect fixture creation time. This is the original workload shape, not the original database image or native Wayland environment.

The probe samples only the fixture-owned application, checks exact received-row totals and retained-page range navigation, waits ten seconds after completion and close, and stops at 4 GiB RSS. It uses private Xvfb, D-Bus and Secret Service state and removes its own container and runtime afterward. The exact [build identity](build.json), [full samples](stream.json), [streaming summary](stream-summary.json) and [cancellation summary](cancel-summary.json) are recorded. The [heap summary](heap-summary.json) and [unmerged allocation report](heap-report.txt) record the separate instrumented run.

The original query has no ORDER BY. Pager checks therefore assert retained row ranges, not a guaranteed relationship between a row ordinal and its id value.


## Uninstrumented observations

Three full cycles completed in 4.981, 4.846 and 4.833 seconds, with 4.16, 4.10 and 4.10 application CPU-seconds through the terminal state. Every cycle reported 2,000,000 received rows and retained rows 1,980,001 through 2,000,000. Pager ranges were checked backward and forward.

Sampled streaming RSS peaks were 220.6, 371.7 and 372.0 MiB. The first cycle had not yet realized all four retained grids during streaming; paging increased its later footprint. Ten seconds after pager traversal and closure, RSS was 353.6, 371.7 and 371.7 MiB. Later cycles settled near the same high-water footprint. RSS did not return to the 181.4 MiB initial level; these observations do not establish allocator ownership or leak freedom.

Five separate cancellation cycles all produced an explicit cancelled outcome in 0.32 to 0.39 seconds. Each server-side check found zero active or idle-in-transaction client backends, and each fresh sentinel query succeeded. Ten-second settled RSS ranged from 215.4 to 233.2 MiB. This is separate from the completion/pager run, not an additional cycle in the same process.

The initial probe failed after completion because its generic accessible-node lookup could match a hidden stack page named like the visible pager. The corrected probe waits for the exact range with label role. The [initial record](initial-probe.json) is incomplete evidence and is not counted as a passing run.

These results do not reproduce the historical multi-GiB growth for this workload. The original report used an older package on native Wayland; the new qualification uses the pinned current release build under Xvfb/Cairo. This is not a matched display-backend or baseline comparison. No claim is made about arbitrary wider data, longer sessions, the system-installed package or a permanent memory plateau.


## Heap attribution

One instrumented cycle completed successfully. Instrumentation increased query duration to 60.952 seconds; this result is not a performance comparison. Heaptrack reported 99.07 MB peak tracked heap and 338.96 MB peak RSS including profiler overhead (decimal MB). Its largest unmerged peak stack, 12.80 MB, passes through PostgreSQL row decoding and `QueryResultBudget::decode_and_admit_row`; another 2.60 MB stack is SQLx string decoding. Other reported stacks include Pixman surfaces, GTK instance creation and Pango glyph storage. Individual stack peaks occur at different times and must not be added.

Heaptrack reported 47.80 MB still outstanding at process exit. That includes unresolved/library stacks and runtime caches; the label “leaked” in its raw report is not proof of a BookiE ownership leak. The Massif-compatible live-heap series and the uninstrumented RSS observations measure different things. Three uninstrumented cycles and one instrumented cycle do not prove a permanent memory plateau or absence of all leaks.

The raw multi-GB trace stays in the ignored local analysis directory. Its hash and the executable identity are recorded so the summarized allocation evidence can be associated with this run. No product code changed in this qualification.
