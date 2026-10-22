# Workspace draft save profiling, 2026-10-22

Tracks [#1341](https://github.com/cozyGarage/BookiE/issues/1341).

## Source trace

On Linux `6caa27f18`, each writer attempt calls `load_locked`, which loads the workspace metadata and every referenced editor draft before applying pending connection updates. The save wrapper clones the combined workspace, and the disk writer clones it again before clearing query bodies from the metadata snapshot. The GTK snapshot builder also clones each open editor query before handing it to the store. The writer itself runs on a background thread.

These are verified source operations, not measured peak memory or a demonstrated cause of the native editor freeze. A comparison must separate retained workspace cache, caller-held text, transient copies and allocator retention.

## Prepared workload

`repeated_large_draft_saves_preserve_other_connections_and_unicode_text` uses temporary storage, four connections and 65,536 repetitions of a Unicode SQL line per connection. It flushes the initial state, then updates and flushes the first connection three times. A fresh store must restore the latest first draft and the exact original text of the other three connections.

This test pins existing behavior. It is not a failing performance regression or a timing assertion. Both cases passed on the unmodified implementation. The exact test binary was saved before profiling; its checksum and source diff are in the [manifest](manifest.json).

## Next measurement

Build the workload once, then run the exact test binary under Heaptrack without concurrent local compilation. Record source and binary hashes, peak heap and stacks attributable to workspace load/save. Compare a single connection with four connections through the same save/flush path. Confirm all observable restoration assertions before accepting measurements. Keep filesystem/cache effects separate from heap allocation evidence.

Any optimization must preserve migration backup, exact Unicode drafts, write ordering, failed-write recovery, flush acknowledgements and external changes. No product code has been changed for this profiling preparation.

## Baseline allocation measurements

| Case | Draft bytes per connection | Peak heap | Instrumented peak RSS |
| --- | --- | --- | --- |
| One connection | 1,245,184 | 10.05 MB | 21.42 MB |
| Four connections | 1,245,184 | 25.00 MB | 37.91 MB |

These values cover the complete test, including fixture construction, initial saves, three updates and restoration into a fresh store. They do not isolate update-only cost or prove a leak. More connections necessarily retain more valid data. The four-connection allocation report contains clone stacks through `save_locked`, consistent with the source trace; merged stack peak totals are not additive. No optimized comparison or CPU improvement is claimed.

The recorder reports approximately 1.65 KB outstanding at process exit in both cases. This has not been diagnosed as a product leak. Runs are short debug-test workloads, not native application RSS measurements. Other machine activity was not controlled, so elapsed times are not used for performance claims.

The first Heaptrack invocation automatically opened its viewer. That owned viewer was immediately stopped. Subsequent recording used `--record-only`; no desktop capture or interaction occurred. Raw traces and reports remain under `~/bookie-test/workspace-save-profile/`.

## Ownership optimization

The save wrapper and disk writer now consume their owned workspace snapshot instead of cloning it twice. All callers already owned the snapshot and did not use it afterward. Pending states remain retained separately for failed-write recovery. The load, clamp, migration backup, atomic write and acknowledgement operations retain their existing order. This change does not yet avoid rereading and rewriting unrelated drafts.

All eight persistence integration tests and forty workspace-focused unit tests passed, including legacy migration backup, failed writes, pending-save retry, preview cleanup, connection removal and exact Unicode restoration.

Three repeated four-connection recordings of the saved baseline binary each measured 25.00 MB peak heap. Three recordings of the candidate each measured 18.77 MB, approximately 25% lower for this workload. An earlier candidate run measured 18.78 MB. These are complete debug-test heap peaks, not application RSS, CPU benchmarks or a proof of leak freedom. Functional tests pin existing behavior and are not presented as failing performance assertions. Full preflight and app-services all-target Clippy passed. Forgejo acceptance remains pending.
