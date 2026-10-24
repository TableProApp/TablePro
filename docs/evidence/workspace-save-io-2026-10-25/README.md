# Workspace draft save I/O profile

Tracks [issue #1341](https://github.com/cozyGarage/BookiE/issues/1341).

## Workload and method

The `tablepro-app-services` benchmark creates one or four connections. Each has an editor draft containing 65,536 copies of `SELECT '東京é';\n` (1,245,184 UTF-8 bytes). It flushes the initial state, updates the first connection three times with a flush after each update, then restores every connection from a fresh store and checks the exact query text.

Each measurement ran in its own process with `cargo bench`'s optimized profile. Three runs were recorded per connection count on the baseline and candidate. The baseline is Linux `3db4bfd`. The candidate contains the source diff identified by SHA-256 in [profile-results.json](profile-results.json). Both benchmark binary hashes and all individual samples are recorded there.

The benchmark can be rerun with:

```bash
WORKSPACE_PROFILE_CONNECTIONS=4 \
WORKSPACE_PROFILE_OUTPUT=/tmp/workspace-save-io.json \
cargo bench -p tablepro-app-services --bench workspace_save_io
```

Use `WORKSPACE_PROFILE_CONNECTIONS=1` for one connection. Run the command three times per case, with a different output path each time.

## Median results

| Connections | Metric across three updates | Baseline | Candidate |
| ---: | --- | ---: | ---: |
| 1 | Process read characters | 3,738,764 | 2,487 |
| 1 | Process write characters | 3,736,284 | 3,736,284 |
| 1 | CPU runtime | 11.94 ms | 7.99 ms |
| 1 | Save and flush elapsed time | 11.63 ms | 7.87 ms |
| 1 | Whole-process peak RSS | 12,636 KiB | 12,580 KiB |
| 4 | Process read characters | 14,949,198 | 4,375 |
| 4 | Process write characters | 14,944,821 | 3,738,165 |
| 4 | CPU runtime | 30.03 ms | 7.08 ms |
| 4 | Save and flush elapsed time | 29.66 ms | 7.07 ms |
| 4 | Whole-process peak RSS | 22,360 KiB | 17,516 KiB |

For four connections, the save path reads about 14.95 MB fewer characters and writes about 11.21 MB fewer characters over the three updates. All six runs on both versions restored the exact latest draft and the unchanged drafts.

The integration regression failed on the unfixed implementation because an unrelated draft file's inode changed during the save. It passes with the targeted update path and also verifies that the externally edited bytes and persisted draft ID remain intact.

## Interpretation

`read_chars` and `written_chars` are Linux `/proc/self/io` counters for the benchmark process, including its threads, workspace metadata and small procfs samples. They count bytes passed through read/write calls, not physical storage I/O. CPU runtime sums scheduler runtime from the process threads. Elapsed time covers the three save/flush cycles. Peak RSS is the high-water mark of this benchmark process, including setup and restore; it is not a native BookiE GUI measurement.

The source change avoids loading unrelated draft bodies and writes draft files only for updated connections. The lower four-connection CPU and elapsed values match that reduction in this isolated benchmark. These results do not establish GUI responsiveness, production RSS, or leak freedom. The functional regression also checks that an external edit to another connection's draft survives a save and that its draft file is not replaced.

An allocator-level Heaptrack comparison at the Linux baseline and merged candidate is recorded in [workspace-save-heaptrack-2026-10-25](../workspace-save-heaptrack-2026-10-25/README.md). It confirms that the four-connection workload has the same complete-process peak heap on both heads; the I/O optimization should not be described as a four-connection peak-heap reduction.
