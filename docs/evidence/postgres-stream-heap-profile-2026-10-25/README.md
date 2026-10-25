# PostgreSQL large-result heap profile

This profile follows [issue 1272](https://github.com/cozyGarage/BookiE/issues/1272) on Linux source commit `fa50f371c6ba0e81ca0d7cca568d9328dd8b0fd4`. It used a release binary and a disposable PostgreSQL 16 container with the issue's two-million-row, ten-column `SELECT * FROM big` workload. Build and tool identities are recorded in [build.json](build.json). The raw process samples are in [profile.json](profile.json) and [profile-uninstrumented.json](profile-uninstrumented.json); the sanitized Heaptrack allocation report is compressed in [heaptrack-report.txt.gz](heaptrack-report.txt.gz).

## Results

| Measure | Heaptrack-instrumented run | Uninstrumented run |
| --- | ---: | ---: |
| Query completion | 134.681 s | 12.505 s |
| Process CPU through completion | 56.53 s | 12.57 s |
| RSS before query | 248.8 MiB | 174.3 MiB |
| RSS after query settled | 554.1 MiB | 498.6 MiB |
| RSS three seconds after closing editor | 556.0 MiB | 500.5 MiB |

These were separate runs on a loaded host and are not an apples-to-apples performance comparison. Heaptrack reported 266.79 MiB peak heap and 583.00 MiB peak RSS including profiler overhead. It also reported 79.40 MiB as memory not freed at process exit; this is not proof of a BookiE leak and is not a post-close live-allocation measurement.

The largest attributable peak allocation group was 74.24 MiB across 4,000,000 allocations in PostgreSQL row collection, including the `Vec<Value>` built by `collect_query_rows` and row admission through `QueryResultBudget::decode_and_admit_row`. Heaptrack also attributed 69.03 MiB peak to `g_malloc0`; its largest named GTK substack accounted for 4.13 MiB across 36,900 allocations. Peak allocation attribution does not identify which allocations remain live after the editor closes.

Both runs received 2,000,000 rows across 400 pages and retained rows `1,855,001–2,000,000` (145,000 rows). The earlier rows were unavailable. The probe navigated four adjacent retained pages in both directions; it did not traverse the full retained interval.

## Scope and limits

- The application was a source-built release binary running under Xvfb/Cairo with a private D-Bus session and temporary Secret Service keyring. This was not an installed Arch package or native Wayland run.
- The Docker fixture used a pinned PostgreSQL 16 image digest. The script removes only the container it creates.
- This measures one full query cycle and a short post-close interval. It does not establish long-session leak freedom or retained-allocation ownership after close.
- The host was under unrelated database-container load. Do not compare these timings directly with prior profiles or use them as a performance regression signal.
- Debian package validation was unavailable on the Arch host because `dpkg-deb` is not installed. The Ubuntu packaging workflow remains the appropriate environment for that check.

Run `bash docs/evidence/postgres-stream-heap-profile-2026-10-25/run.sh <output-directory>` after building the installed release test binary with `TABLEPRO_GTK_BUILD_PROFILE=release bash scripts/gtk-test-binary.sh`. Set `HEAPTRACK=0` for an uninstrumented sample. The script creates an isolated PostgreSQL container and temporary desktop state.

The report improves current-source allocation attribution, but issue 1272 remains open for longer-session and installed-package acceptance. Earlier-row navigation is tracked separately in [issue 554](https://github.com/cozyGarage/BookiE/issues/554).
