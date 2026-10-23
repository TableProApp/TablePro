# Loaded export allocation probe

Date: October 23, 2026. Related change: [#1500](https://github.com/cozyGarage/BookiE/pull/1500). Profiler: `heaptrack 1.5.0`.

Both builds start from Linux `e6f73eca9`, with identical dependencies and the unoptimized Cargo test profile. The baseline adds only the synthetic probe. The after build uses the shared-snapshot implementation from #1500 and the same probe with an Arc-owned initial snapshot. Exact source patches and three profiler summaries per build are stored alongside this document.

The workload holds 128 rows of 128 text cells of 1,024 bytes, 16 MiB of text. It models the dialog-to-file-request clone and calls the real job_source helper for the file-request-to-worker handoff. All three owners remain live together through black_box; the test verifies the loaded values. It does not initialize GTK, write a file or simulate the full UI. The retained source snapshot is unchanged.

| Build | Peak tracked heap, each of three runs | Allocation calls, each run |
| --- | --- | --- |
| Baseline | 52.16 MB | 51,599 |
| Shared snapshot | 17.55 MB | 18,574 |

The tracked heap reduction is 34.61 MB, approximately 66.4%, in this synthetic handoff. Allocation calls decrease by 33,025. Heaptrack uses decimal units in these summaries. These measurements do not establish application RSS savings, grid widget memory savings, production-profile timings or leak freedom. Profiler RSS includes profiler overhead and is not used for the comparison.

Preserved executable SHA-256:

- Baseline: `95410e7aad7e79213ddcaa7451f4e79e0ce7266bec6a07371dd854170455f366`.
- Shared snapshot: `3fb69822b36acc7e2cc3923df9fb0fa2036fcefd8d08eccbdb4cd59e06cf27aa`.

Reproduction: apply one patch to an isolated checkout of the recorded base, build `cargo test -p tablepro-app --lib profile_loaded_export_snapshot_allocations --no-run`, then run the resulting test executable under `heaptrack --record-only --output probe <test-executable> --exact ui::export_dialog::tests::profile_loaded_export_snapshot_allocations --test-threads=1`. Analyze the recorded file with `heaptrack_print -f probe.zst -p 0 -a 0 -T 0`. Run each build three times. Source patches are experiments and are not production changes.
