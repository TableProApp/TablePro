# Optimized PostgreSQL streaming investigation

Source: candidate `12519fa76c0d9bda3f8fb1680faa5fc10b205d1e` from [#1520](https://github.com/cozyGarage/BookiE/pull/1520). Build profile: Cargo release, not the shipping dist profile. This is an incomplete performance investigation, not current Linux acceptance. [#1523](https://github.com/cozyGarage/BookiE/issues/1523) owns the next isolation and regression work.

The first isolated Xvfb/Cairo run requested two million generated PostgreSQL rows across six columns. The fixture configures a 60-second query deadline. The app displayed Query timed out after receiving 1695000 rows over 339 pages. It explicitly retained rows 1675001-1695000. The probe incorrectly waited only for success, so its final failure arrived after a 300-second observation bound. It produced no completed memory measurement. The [failure log](initial-failure.log) is preserved; this is not a successful two-million-row result.

A separate disposable PostgreSQL 17 container ran the same SELECT through psql with output discarded in 1.801 seconds. The [control](psql-control.json) does not reproduce SQLx decoding, GTK presentation or accessibility polling and is not an equivalent client benchmark. It justifies investigating the client path, without assigning a root cause.

The first [probe](probe-initial.py) repeatedly scanned the accessible result tree while waiting for success. That can affect client CPU and throughput. The [follow-up probe](probe-low-poll.py) used only the cached Run-button sensitive state during execution. It recorded a timed-out terminal outcome at 60.677 seconds, with 1225000 rows received and rows 1205001-1225000 retained. Its fixture invocation passed because it correctly recorded and checked that outcome; the two-million-row completion acceptance did not pass. No leak, release regression or driver-specific cause is established.

| Follow-up app memory | RSS, KiB | Process lifetime high-water, KiB |
| --- | ---: | ---: |
| Before query | 183580 | 183580 |
| Terminal result, settled 3 seconds | 231436 | 231436 |
| After closing query, settled 3 seconds | 234452 | 234452 |

The largest periodic RSS sample was 231388 KiB. These [measurements](low-poll-measurements.json) do not show RSS returning to its starting level after one close, but one cycle cannot distinguish retained live objects from allocator reuse or establish a leak. Both probes ran during other local development checks, so their differing received-row counts are not a controlled comparison of polling overhead. The second result confirms that eliminating repeated result-tree scans did not establish completion under the configured deadline.

The [fixture adaptation](run-fixture.sh) creates and removes its own database and private keyring. Reproduce with TABLEPRO_PROFILE_REPO pointing to the recorded candidate, TABLEPRO_PROFILE_FIXTURE pointing to that adaptation, TABLEPRO_PROFILE_RUNNER using the existing [private runner adaptation](../grid-keyboard-menu-routing-2026-10-23/runner.patch), TABLEPRO_PROFILE_SCRIPT pointing to the selected probe, TABLEPRO_GTK_BINARY pointing to the recorded immutable executable, TABLEPRO_GTK_SCENARIO=profile_postgres_large_stream, TABLEPRO_GTK_SCENARIO_RETRIES=0, TABLEPRO_PROFILE_ROWS=2000000 and TABLEPRO_PROFILE_OUT pointing to an owned result file. The probe's diagnostic record accepts an explicit timeout; completion must be checked separately.

[Build identities](build.json) record the optimized executable, initial probe, fixture and database image. The disposable database and test application from the first run were removed by the fixture cleanup.

## Driver and UI cost isolation

The [raw-driver control](raw-driver.json) used the same generated SELECT through the PostgreSQL driver cursor API, checked all two million row IDs in order, and discarded each page. It completed 401 fetches, including the empty final page, in 3.367 seconds. Process wall time was 3.37 seconds, user CPU 2.19 seconds, system CPU 0.07 seconds and peak RSS 8816 KiB. This excludes PolicyGuard, audit, GTK and accessibility. It does not compare equivalent retention or presentation workloads. The example target also enables app dev-dependency features, which can differ from the GUI binary's feature union.

The [control source](diagnostic_pg_stream.rs), [identity](raw-driver-build.json) and [resource record](raw-driver-resource.txt) are preserved. To reproduce on the recorded candidate, copy the source to apps/linux/app/examples/diagnostic_pg_stream.rs, build with cargo build --release --locked -p tablepro-app --example diagnostic_pg_stream, then run against a disposable loopback-only PostgreSQL fixture with its published port and an owned output path as the two arguments. The diagnostic fixture uses trust authentication and the source permits only 127.0.0.1; it is not a production connection setup.

A separate app run used the same immutable GUI executable and cached-button probe with perf attached only to the owned app process. It timed out at 61.150 seconds after receiving 1425000 rows. The [recording](cpu-recording.json) contains 6121 user CPU-clock samples at 99 Hz, with no reported lost samples. The [instrumented probe](probe-perf.py), [outcome and memory samples](2000000-perf.json), [library distribution](cpu-libraries.txt), [inclusive symbol report](cpu-cumulative.txt) and [recording log](cpu.txt) preserve its scope. Raw perf data is kept locally because stack captures are larger and may contain process data; its hash is recorded.

| Sampled leaf location | Share |
| --- | ---: |
| GTK | 25.73% |
| GObject | 19.05% |
| GLib | 17.12% |
| libc on the app main thread | 13.97% |
| HarfBuzz | 9.07% |
| Pango | 7.25% |
| App code on Tokio worker threads | 2.53% |

Inclusive stacks contain gtk_label_set_text at 27.51%, gtk_widget_create_pango_layout at 16.78% and gtk_stack_remove at 8.46%. Inclusive percentages overlap and must not be added. Optimized and system-library symbols leave some frames unresolved. The source still creates a lazy grid for each newly presented stream page. Together, the driver control and app samples make GTK result updates the next investigation target; they do not prove that one function or widget owns the entire slowdown. Compilation overlapped part of the CPU-recorded run, and perf adds overhead, so this is hotspot evidence rather than a controlled timing comparison.
