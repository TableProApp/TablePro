# Multi-editor streamed-result retention profile

This profile measures two editor result owners plus one synthetic in-flight export page on Linux commit `5f7871c67ace0fe8e83663c08adbe9cf89b76fb2`.

## Workload

Each editor holds four pinned results and one active streamed result. Each unique page has one row and 60 binary cells of 256 KiB each. The per-page estimate is 15,730,584 bytes, below the 64 MiB per-result cache limit. The two editors hold ten unique pages with 157,305,840 estimated payload bytes.

The profile then creates a separate row page of the same shape behind a temporary `PageFetcherFactory`. It cancels the factory token before delivery and verifies that the page owner is released. This is a synthetic in-memory cancellation probe. It does not open a database cursor or test the database driver's cancellation and cleanup path.

The ignored test is applied from `profile-probe.patch` and is not product source or part of the default suite. Reproduce it from the repository root:

```sh
rtk proxy git apply docs/evidence/stream-retention-multi-owner-2026-10-26/profile-probe.patch
rtk proxy cargo test --locked -p tablepro-app --lib profile_two_editor_and_cancelled_export_page_owners -- --ignored --nocapture --test-threads=1
rtk proxy git apply -R docs/evidence/stream-retention-multi-owner-2026-10-26/profile-probe.patch
```

Environment: Rust and Cargo 1.98.1, Linux 7.2.8-9-omarchy, x86_64. The debug test process samples `VmRSS` and `VmHWM` from `/proc/self/status`.

## Results

| Run | Baseline RSS | Two editors RSS | Editors plus export page RSS | After export cancellation RSS | After editor teardown RSS | Maximum sampled VmHWM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 38 MiB | 183 MiB | 198 MiB | 184 MiB | 184 MiB | 198 MiB |
| 2 | 38 MiB | 183 MiB | 198 MiB | 184 MiB | 184 MiB | 198 MiB |
| 3 | 38 MiB | 183 MiB | 199 MiB | 184 MiB | 184 MiB | 199 MiB |

Weak references confirmed that all ten editor pages remained alive while their editors owned them, the synthetic export page was released on cancellation, and all editor pages were released after both editor states dropped. RSS decreased by about 15 MiB after export cancellation but stayed about 46 MiB above baseline after editor teardown. The weak-reference checks show the pages were released; RSS remaining high is allocator/process behavior and does not establish that the payloads remain owned. HWM is cumulative and does not fall when owners release memory.

An instrumented repeat also printed raw `VmHWM` values in KiB. Across three samples, the value read with the export page was 203,472, 203,392 and 203,224 KiB; after cancellation it read 203,292, 203,640 and 203,100 KiB. Since the sampled value can move slightly in either direction, the table reports the maximum observed across stages. The [upstream Linux `/proc` implementation](https://code.googlesource.com/linux/+/7b1b868e1d9156484ccce9bf11122c053de82617/fs/proc/task_mmu.c) notes that its high-water and RSS snapshots can be inconsistent because the kernel updates high-water counters lazily. Treat these as process samples, not exact allocator peaks.

## Limits

This is a synthetic debug-test profile, not an installed app, GTK session, database query, driver-cancellation test or allocator profile. The export page uses a fake page fetcher and cancellation token. It measures two editor states at five unique pages each and one separately allocated page, not every export, session, render, decode or database-buffer owner. The RSS values are process-level samples with MiB resolution. This profile does not establish a production aggregate memory ceiling.

The current source trace for export ownership is recorded on [issue #1032](https://github.com/cozyGarage/BookiE/issues/1032). A database-backed cursor-cancellation and cleanup acceptance remains separate work.
