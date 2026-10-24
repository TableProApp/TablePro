# Workspace draft save allocator profile

Supplemental allocator evidence for [issue #1341](https://github.com/cozyGarage/BookiE/issues/1341) and the I/O profile in [workspace-save-io-2026-10-25](../workspace-save-io-2026-10-25/README.md).

## Workload and source identity

The existing `workspace_save_io` benchmark prepares one or four connections with a 1,245,184-byte Unicode SQL draft each, flushes the workspace, updates the first connection three times with a flush after each update, and restores every connection through a fresh store. Every run reported exact restoration passed.

The before binary was built at `ff47ffde452e1b0ad735f108d2974aaf191abbda`, immediately before [#1612](https://github.com/cozyGarage/BookiE/pull/1612). The after binary was built at its merged commit `5c95fe813f1e775c57debba534718ac5cb8f487c`. The benchmark harness was added to the baseline worktree from the candidate commit so both binaries ran identical benchmark code. `crates/app-services` had no intervening change between the previous 3db4 profile baseline and ff47; the profile uses the direct pre-#1612 head for this comparison.

Each head used a separate `CARGO_TARGET_DIR` and independently built optimized benchmark executable. Heaptrack 1.5.0 ran each executable in a fresh process with `--record-only`; the raw trace was then read with `heaptrack_print`. Three runs were recorded for each connection count and version. Uninstrumented runs of the same binaries separately measured process read/write characters, CPU runtime, elapsed time, and high-water RSS.

## Results

The table shows medians across three runs. Heaptrack's peak is for the full benchmark process, including fixture setup and restoration. It is not update-only live heap.

| Connections | Metric | Before #1612 | After #1612 |
| ---: | --- | ---: | ---: |
| 1 | Heaptrack peak heap | 8.80M | 7.55M |
| 1 | Heaptrack peak RSS | 17.17M | 14.91M |
| 1 | Uninstrumented read characters | 3,738,766 | 2,497 |
| 1 | Uninstrumented write characters | 3,736,284 | 3,736,284 |
| 1 | Uninstrumented CPU runtime | 11.00 ms | 7.31 ms |
| 1 | Uninstrumented save/flush elapsed | 9.96 ms | 6.46 ms |
| 1 | Uninstrumented process peak RSS | 12,408 KiB | 12,644 KiB |
| 4 | Heaptrack peak heap | 18.76M | 18.76M |
| 4 | Heaptrack peak RSS | 29.41M | 21.18M |
| 4 | Uninstrumented read characters | 14,949,204 | 4,384 |
| 4 | Uninstrumented write characters | 14,944,821 | 3,738,165 |
| 4 | Uninstrumented CPU runtime | 24.38 ms | 7.40 ms |
| 4 | Uninstrumented save/flush elapsed | 24.09 ms | 7.31 ms |
| 4 | Uninstrumented process peak RSS | 22,048 KiB | 17,516 KiB |

The four-connection run reduces measured read characters by about 14.94 MB and write characters by about 11.21 MB over three updates. Its full-process Heaptrack peak remains 18.76M because this workload's setup and retained drafts determine the high-water peak. The one-connection peak falls by 1.25M. The change therefore has strong I/O and CPU evidence, but does not show a four-connection peak-heap reduction.

Heaptrack changes allocation timing and raises RSS, so its RSS and timing are not used as performance results. The uninstrumented process I/O counters count bytes passed through read/write calls, not physical device I/O. The benchmark measures `WorkspaceStore`, not GTK rendering or native application memory. The identical 1.30K reported outstanding allocation at process exit is not treated as a leak.

## Reproduction

Build each head with the same benchmark source and a different target directory:

```bash
CARGO_TARGET_DIR=/tmp/bookie-workspace-heap-before cargo bench -p tablepro-app-services --bench workspace_save_io --no-run
CARGO_TARGET_DIR=/tmp/bookie-workspace-heap-after cargo bench -p tablepro-app-services --bench workspace_save_io --no-run
```

Run each resulting executable for `WORKSPACE_PROFILE_CONNECTIONS=1` and `4`, setting a unique `WORKSPACE_PROFILE_OUTPUT`. For the allocator capture, prefix the executable with:

```bash
heaptrack --record-only -o /tmp/workspace-profile /path/to/workspace_save_io
heaptrack_print -f /tmp/workspace-profile.zst
```

The measured source commits, binary hashes, exact samples, and hashes of the twelve raw Heaptrack traces are in [profile-results.json](profile-results.json). Source-file digests are in [manifest.json](manifest.json).
