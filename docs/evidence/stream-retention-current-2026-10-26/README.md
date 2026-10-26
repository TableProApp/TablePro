# Current streamed-result retention profile

This profile measures retained page payloads for four pinned results and one active result on Linux commit `0208ec6f5ea34ca9f5dd6dc74435f0e9a34233a7`.

## Workload

The test creates five independent `QueryResult` pages. Each page has one row and 60 binary cells of 1 MiB each. `QueryResultBudget::admit` accepts each row. The page estimate is 62,916,504 bytes, below the per-result 64 MiB limit of 67,108,864 bytes. Four completed outcomes are pinned; a fifth is the active outcome. The test then builds and previews one shared `RowObject` per result and drops every result owner.

The test is a one-off probe applied from `profile-probe.patch`; it is not part of the product source or default test suite. Reproduce it from the repository root:

```sh
rtk proxy git apply docs/evidence/stream-retention-current-2026-10-26/profile-probe.patch
rtk proxy cargo test --locked -p tablepro-app --lib profile_current_stream_pin_and_preview_owners -- --ignored --nocapture --test-threads=1
rtk proxy git apply -R docs/evidence/stream-retention-current-2026-10-26/profile-probe.patch
```

Environment: Rust and Cargo 1.98.1, Linux 7.2.8-9-omarchy, x86_64. The debug unit-test process reads `VmRSS` and `VmHWM` from `/proc/self/status` at each stage.

## Results

| Sample | Baseline RSS / HWM | Four pins RSS / HWM | Pins plus active RSS / HWM | After visible previews RSS / HWM | Estimated retained bytes | Cells retained | Pages after dropping all owners |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 39 / 41 MiB | 288 / 288 MiB | 353 / 353 MiB | 353 / 353 MiB | 314,582,520 | 300 | 0 |
| 2 | 38 / 40 MiB | 288 / 288 MiB | 352 / 352 MiB | 352 / 352 MiB | 314,582,520 | 300 | 0 |
| 3 | 38 / 40 MiB | 288 / 288 MiB | 353 / 353 MiB | 353 / 353 MiB | 314,582,520 | 300 | 0 |

All five unique pages remain alive through the four pins and active result. Weak references confirm that every page is released after those owners and the visible preview rows are dropped. Preview construction did not measurably increase RSS at MiB resolution.

## Limits

This is a synthetic, single-editor Rust test, not a native GTK or database run. It covers 60 wide binary cells and the result/pin/preview ownership path. It does not measure multiple editors, export tasks, cancellation overlap, database buffers, or actual process behavior during a GUI session. The figures are current RSS and process high-water mark for the test process, not an allocator profile. The test establishes no production aggregate budget.

The older [synthetic profile](../stream-retention-synthetic-2026-10-16/README.md) constructed four maximum-sized pages directly in each result and predates the current per-result 64 MiB cache. Its 1.25 GiB measurement is not a current-cache baseline. The current profile retains about 300 MiB of estimated page payload for four pins plus one active result. Cross-editor and export ownership still need separate measurement before choosing a shared limit.
