# Local application resource investigation

Status: in progress; local candidate for #1528, not merge acceptance. Source baseline: `325802075` on Linux. These checks use isolated test data and Xvfb on the development desktop. They do not establish native Wayland visual acceptance.

## Acceptance

Measure optimized application behavior before changing it. Preserve exact values, bounded retention, policy and audit, cancellation, export semantics, keyboard access and tab cleanup. Keep a change only when a matching comparison demonstrates its benefit and its regression checks pass. Record negative experiments as well.

## Local scenarios

| Scenario | Measurements and checks | Status |
| --- | --- | --- |
| Startup and idle | Startup time, idle CPU, RSS and private memory | Pending |
| PostgreSQL streamed results | 250k, 1M and 2M six-column rows; completion or explicit timeout; retained range; CPU, elapsed time and RSS | 250k cycles recorded; 1M and 2M pending |
| Wide results and browse | Bounded bytes, scrolling, visible previews, exact copy and export | Pending |
| Large SQL files | 1 MiB and near the 8 MiB limit; UTF-8; load, edit and close; oversized refusal | ASCII restore/edit/discard recorded; chooser, UTF-8 and refusal pending |
| Repeated open and close | Repeated editor and result cycles; settled memory, live allocations and responsive welcome view | Pending |
| Cancellation and failure | Cancel during streaming; query failure; release of retired pages | Pending |

Recorded timing runs had no competing compilation on this desktop. Heaptrack and perf runs are diagnostic and their timings must not be treated as ordinary execution times. Record executable identity and toolkit versions with results.

The previous [PostgreSQL investigation](../postgres-optimized-stream-2026-10-23/README.md) provides driver/UI cost isolation. Its widget-reference caching experiment showed no reliable elapsed-time or memory improvement and was discarded; the update is recorded on [issue 1523](https://github.com/cozyGarage/BookiE/issues/1523#issuecomment-6366101956).

## Baseline observations

Five sequential 250k-row PostgreSQL query/close cycles completed in 8.33, 8.80, 8.70, 8.50 and 8.49 seconds. CPU time per query was 8.16, 8.68, 8.52, 8.36 and 8.33 seconds. Post-close private dirty memory was 94168, 105936, 108408, 111956 and 114252 KiB. The [cycle samples](stream-250k-cycles.json) show growth, not proof of a leak. Each cycle reported the same bounded retained range.

The [saved-file scenarios](sql-files.json) restore workspace contents backed by a real SQL file; they do not time the file chooser. A 1 MiB script restored in 2.513 seconds and acknowledged a keystroke in 0.082 seconds. An 8388600-byte script restored in 5.573 seconds and acknowledged a keystroke in 0.186 seconds. Both discarded edits without changing the original file and then completed another query. The larger script used 312840 KiB RSS when first visible, 354636 KiB after settling, 430948 KiB after editing and 555180 KiB after close. This is one run per size.

A [simple-input-method diagnostic](sql-files-simple-im.json) still ended at 556456 KiB RSS for the larger file. Forcing a different input method is therefore not a supported fix for this workload. The [empty folding-tag probe](probe-empty-fold-clear.py) took only microseconds per operation, so skipping empty tag removal is not justified by these measurements.

The [allocation report](file-allocation-report.txt) records 132389916 allocation calls and a 317.25 MB peak tracked heap during an instrumented large-file cycle. GtkSourceView regex and highlighting paths account for many calls. The fixture terminates the app with SIGTERM, so the report's outstanding-at-exit allocations must not be described as confirmed leaks. Raw data stays in the worktree target directory; [trace identity](heaptrack-identity.json) preserves its hash. The first instrumented run hit the ordinary window timeout; the completed diagnostic allows 120 seconds for its instrumented startup. The [instrumented resource measurements](sql-files-heaptrack.json) are not ordinary timing evidence.

## Candidate: stop highlighting on editor shutdown

The existing editor-lifetime regression was extended to keep an external buffer reference until component shutdown and check that syntax highlighting stops. It fails on the baseline with `closed editor still highlights its buffer`. The candidate turns off highlighting only during shutdown. Open editors retain their current syntax highlighting and input method. This check proves shutdown state, not an end-to-end resource improvement; paired file measurements remain required before keeping the candidate.

The first shutdown-only candidate disabled highlighting but retained the language engine. The [ordinary candidate run](sql-files-shutdown-candidate.json) ended at 534784 KiB RSS and 21.75 process CPU seconds, against 555180 KiB and 20.62 CPU seconds for the baseline. Startup varied from 5.573 to 12.852 seconds, so this pair establishes no reliable improvement.

For early close immediately after restored contents appear, the [baseline](sql-files-early-base.json) grew from 273164 to 472248 KiB RSS and from 4.56 to 11.43 process CPU seconds over close and ten seconds of settling. The [highlight-disabled candidate](sql-files-early-candidate.json) grew from 279036 to 464260 KiB RSS and ended at 15.80 CPU seconds. Disabling highlighting alone did not solve this workload. A subsequent candidate releases the language engine during shutdown as well.

## Reproduction

Build the recorded source with `cargo build --release --locked -p tablepro-app --bin tablepro-app` and copy the executable into an owned installed-layout directory ending in `usr/bin/tablepro`. Set `TABLEPRO_PROFILE_REPO` to the checkout, `TABLEPRO_GTK_BINARY` to that immutable executable and `TABLEPRO_PROFILE_RUNNER` to the absolute path of [run-probe.sh](run-probe.sh). The runner is preserved from the earlier isolated-display adaptation. Set `TABLEPRO_PROFILE_SCRIPT` to [probe-stream.py](probe-stream.py) or [probe-files.py](probe-files.py), and `TABLEPRO_PROFILE_OUT` to an owned JSON file.

For PostgreSQL set `TABLEPRO_PROFILE_FIXTURE` to the absolute path of the existing [disposable fixture](../postgres-optimized-stream-2026-10-23/run-fixture.sh), select `TABLEPRO_GTK_SCENARIO=profile_postgres_large_stream`, set `TABLEPRO_PROFILE_ROWS=250000` and `TABLEPRO_PROFILE_REPETITIONS=5`, then invoke the fixture with Bash. For saved SQL files select `TABLEPRO_GTK_SCENARIO=profile_sql_files` and invoke the runner with Bash. `TABLEPRO_PROFILE_FILE_BYTES=8388608` limits the file probe to the larger case; `TABLEPRO_PROFILE_EARLY_CLOSE=1` closes it as soon as restored text appears. Otherwise the file probe edits, discards and checks subsequent responsiveness. Set `TABLEPRO_GTK_SCENARIO_RETRIES=0` for all measurements.

For allocation diagnostics only, set `TABLEPRO_PROFILE_HEAP_DIR` to an existing owned directory. Each process writes raw Heaptrack data there through the installed preload library. Interpret the trace with the installed `heaptrack_interpret`, compress with zstd and inspect with `heaptrack_print`. The heaptrace includes synthetic data only.

## Language-engine release

Related: [issue 1528](https://github.com/cozyGarage/BookiE/issues/1528). The candidate additionally clears the retired buffer's language during component shutdown. In the [first early-close run](sql-files-early-engine-candidate.json), RSS rose only from 288316 to 288920 KiB over close and ten seconds of settling. The baseline grew from 273164 to 472248 KiB in the matching workload. This is about 179 MiB less settled RSS for the candidate in that pair. Its post-load CPU increment was 5.39 seconds, compared with 6.87 seconds for the baseline.

The [candidate edit/discard scenario](sql-files-engine-candidate.json) restored in 5.118 seconds and acknowledged an edit in 0.188 seconds. It left the source file unchanged and completed a subsequent query. Its final RSS was 548448 KiB, close to the 555180 KiB baseline. This limits the claim: releasing the engine helps avoid continued analysis after early closure; it does not establish low memory use while a large script stays open or after highlighting has already completed.

The [baseline repeat](sql-files-early-base-repeat.json) grew from 313208 to 512400 KiB RSS; the [candidate repeat](sql-files-early-engine-repeat.json) grew from 311996 to 312628 KiB. Post-load CPU increments were 6.88 and 5.34 seconds. Across both early-close pairs the baseline gained about 199000 KiB, while the candidate gained 604 and 632 KiB. Startup times were 5.05–5.16 seconds. This repeat supports the bounded claim about avoiding continued highlighting work after early close.

Raw and partial traces created by this investigation were removed after verifying the completed compressed trace with `zstd -t`; 5.86 GiB was reclaimed. The completed compressed trace and immutable binaries remain in this worktree's ignored target directory.

## Validation status

Local preflight passed, including 2073 non-GTK unit tests and 2086 sandbox tests. Application all-target Clippy passed. Application unit tests passed 788 cases, with 191 display or fixture cases ignored by that invocation. All 153 registered isolated GTK widget scenarios passed, including the extended shutdown regression. Documentation links, issue index and ignored-test inventory passed. The [validation record](validation.json) owns the structured result.

The local commit command was rejected by execution policy, so the candidate remains uncommitted and has no Forgejo or merge acceptance. Its source base precedes the later save-conflict wording change; the performance evidence qualifies only the recorded baseline and candidate. Native Wayland visual acceptance, broad engine coverage and the unfinished scenario rows above remain outstanding.

## Two-million-row streaming baseline

A [current isolated baseline run](stream-2m-baseline.json), with no competing compilation, reached the explicit timeout at 60.65 seconds after receiving 1880000 rows over 376 pages. It used 61.82 process CPU seconds during the query and reported retained rows 1860001–1880000. This diagnostic invocation passed because it checks an explicit terminal outcome; successful two-million-row completion was not achieved.
