# Grid lifetime and memory investigation, October 21

Owner: UX, [#1272](https://github.com/cozyGarage/BookiE/issues/1272), with broader retention acceptance in [#1032](https://github.com/cozyGarage/BookiE/issues/1032). Base: `71cd25e33`. The patch is limited to GTK grid ownership. Driver decoding, policy, stream page limits and paging UX are unchanged.

## Reproduced cause and fix

The column factory setup callback strongly captured its owning ColumnView. The view owned the column and factory, forming a reference cycle. Cell pointer/key callbacks also captured their own widget and view. Editable cells had additional owner back-edges through key and preedit callbacks. Active menu context could retain its own cell through action/controller references.

Factory and controller callbacks now use weak owner references. Menu state stores a weak widget and obtains a strong snapshot only while an action runs. Missing owners end the callback without an edit. Cell values, SQL construction and row-operation routes are unchanged.

A production-grid test fails on the original implementation after dropping the view, selection and result: the detached view remains alive. Rendered read-only and editable cases also retain cells. A composed streamed-widget test fails when an evicted page remains alive. These assertions pass with the fix. The baseline experiments restored the original column, context-menu and editing implementation from the base commit while keeping the same test harness, then restored the fixed files.

Six isolated GTK cases cover an unrealized grid, a rendered result grid with menus and local filter/sort state, a rendered editable grid, eight repeated replacements, weak menu context after cell removal, and actual streamed-result widgets. The latter delivers twelve 5,000-row pages through the existing four-page cache, verifies eviction releases earlier pages, retains the last four during the cancelled-result display, then verifies all pages release on close. It does not execute database cancellation or prove pin/export cursor cleanup.

## Heaptrack comparison

Same synthetic workload in both builds: eight sequential rendered grids, 1,000 text rows and one column each, menus, result previews and local filter/sort state. Each grid is detached before constructing the next. Runtime: debug test binary on Omarchy, private Xvfb, Cairo and D-Bus session. No database is used for this comparison. Baseline exits with its intended lifetime assertion after constructing all eight grids; fixed exits successfully.

| Heaptrack measurement | Original implementation | Fixed implementation |
|---|---:|---:|
| Peak tracked heap | 63.60 MB | 38.95 MB |
| Live allocations at process exit | 62.23 MB | 33.31 MB |
| Peak RSS, including profiler overhead | 193.86 MB | 165.30 MB |

Heaptrack calls all outstanding allocations at exit leaks. That total includes graphics, font and other process-wide caches and is not an application-only leak count. Graphics-driver stacks dominate the remaining total. Weak-reference assertions independently prove the tested cells, grid, selection and result pages are released. Neither profile is a release throughput benchmark or a claim of universal leak freedom.

Text reports: [baseline](baseline-heap-summary.txt), [fixed](fixed-heap-summary.txt). [Manifest](manifest.json) records the workload and raw-profile checksums. Raw interpreted profiles and test executables are retained in the local `bookie-test/profiles/grid-lifetime-2026-10-21` artifact directory. They are not shipped in Git or packages. Reproduce with `cargo test --locked -p tablepro-app --lib --no-run`, then run the emitted test executable under `heaptrack --record-only` selecting `ui::grid::lifetime_tests::repeated_result_grid_replacement_releases_every_retired_page` with `--ignored --exact --test-threads=1`, under the same isolated display environment.

## Full-app PostgreSQL probe

The patched debug application was launched in its own X11/D-Bus profile against the existing local PostgreSQL 16 `public.big` test table. The only server workload was `SELECT * FROM public.big;`. Samples read `/proc` for the exact launched app PID, once per second. The probe imposed a 2 GiB stop threshold for its own process; the threshold was not reached. It did not stop or modify the existing database container or the desktop application.

The query displayed **80,000 received rows across 16 pages** before cancellation. RSS settled around 361 MiB while streaming; the largest recorded RSS across the sequence was 367.55 MiB. After the visible Cancel action completed, CPU time stopped increasing during the five-second observation, with RSS around 366.24 MiB. Running a replacement `SELECT 1 AS resource_probe;` succeeded; RSS was 367.55 MiB afterward. Thus this probe does not establish return to idle RSS. Source ownership release and process RSS are different measurements.

The complete close measurement is unverified: the probe did not find the expected accessible Close tab button and stopped its own app in cleanup. Earlier attempts are excluded from acceptance: one failed accessibility-bus setup before usable sampling, and another sent Escape without establishing cancellation. The final probe used explicit `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon` and the visible Cancel button. No native Wayland claim follows from these X11 runs.

Samples: [full-app telemetry](postgresql-rss-samples.json). This is not an equivalent release-build comparison to the report's packaged build (`3520c2ad5f13`); it qualifies the observed bounded memory shape for this patched debug build only. CPU remained close to one core during streaming. Merged [PR #1244](https://github.com/cozyGarage/BookiE/pull/1244) owns avoiding full grid reconstruction on every page and should be measured together with this ownership fix. It does not replace the need to release evicted grids.

## Resumed verification on current source

Base `20ee44f3e` includes merged [#1244](https://github.com/cozyGarage/BookiE/pull/1244). The ownership patch applied cleanly. The composed lifecycle regression now exercises `update_live_stream` between pages, then the production terminal-result rebuild and close. Earlier heap profiles remain pinned to their original base.

A second patched debug application completed three PostgreSQL stream/cancel/replacement/close cycles against the same local fixture. Each stream ran for approximately thirty seconds before the visible Cancel action. The probe then ran `SELECT 1 AS resource_probe;` and activated the accessible **Close Tab** button, verifying the editor Run control disappeared. Peak RSS across the full sequence was **378.83 MiB**.

| Cycle | Rows observed before Cancel | RSS after close |
|---|---:|---:|
| 1 | 200,000 | 373.22 MiB |
| 2 | 225,000 | 377.68 MiB |
| 3 | 245,000 | 378.82 MiB |

[Telemetry](postgresql-current-rss-samples.json) and the manifest qualify this build and fixture only. RSS stayed near a plateau but did not return to startup; three cycles do not rule out smaller retained-resource defects. Streaming still consumes approximately one CPU core. Other local compilation occurred during later cycles, so these counts are not controlled throughput benchmarks. Native Wayland, release-build throughput and complete pin/export acceptance remain unverified.

An earlier attempt completed two closes, then its unread stderr pipe filled with repeated toolbar-width warnings and accessibility stopped responding. That attempt is excluded from three-cycle acceptance. The successful probe writes stderr directly to a file. The warnings report an editor toolbar requesting 964 px with 910 px available; the responsive toolbar needs a separate layout regression, tracked in [#1279](https://github.com/cozyGarage/BookiE/issues/1279). No application crash was established by the failed probe.

A separate exploratory editor/search release assertion also failed for a bare GtkSourceView without application callbacks, including after window realization and removal. That control refutes using the assertion as evidence of an application-specific editor leak. Candidate changes were removed; no editor/search retention fix is claimed. A valid native lifetime model is needed before pursuing that hypothesis.

## Optimized-build CPU follow-up

An optimized build of the same current-base patch reached 1,165,000 and 1,205,000 received rows in its first two cycles, followed by successful replacement queries and closes. The third reached 580,000 observed rows, then accessibility no longer found the application for the replacement action while its process remained active. Cleanup stopped only that process. Peak RSS across this incomplete run was **369.58 MiB**; after the first two closes it was 353.09 and 365.19 MiB. The third close is unverified. This run is not a complete three-cycle acceptance or proof of a crash. [Samples](postgresql-release-rss-samples.json) preserve the failure.

Accessibility tree traversal delayed progress/control discovery, so the streams exceeded the intended thirty-second observation and approached the configured 120-second query timeout. Their exact terminal states were not recorded. No release cancellation-latency or throughput claim follows. RSS did not return to startup, and the smaller remaining growth needs separate qualification.

A ten-second `perf` user-space CPU-clock sample captured 833 samples with no reported loss. [Summary](release-cpu-summary.txt): GTK 28.81%, GObject 20.89%, GLib 16.45%, libc 17.41%, HarfBuzz 6.00%, Pango 5.40%, application binary 3.00% self samples. Overlapping cumulative stacks include live-stream updates, label/text layout, object construction and widget removal. Some optimized-library frames remain unresolved. This supports prioritizing GTK page/widget churn for further investigation; it does not isolate one label or prove a driver bottleneck. The sample ran with accessibility and Cairo enabled, and other local compilation occurred, so it is not an uncontended native-desktop benchmark.

Next checks under #1272/#1273: compare without accessibility traversal during streaming, profile native rendering, and evaluate page demand/presentation before changing fetch behavior. Cursor cancellation, tab close and retained-page limits must remain covered. No CPU optimization or paging behavior change is included in this ownership fix.

## Manual observations and remaining work

The test package is `bookie 0.2.0-1`, archive SHA-256 `de8d9d6acb6ac2bccbaf021e39f9005c3067f9285a505dd4259e80cb99e422d5`. The following distinguishes supplied observations from new verification here.

| Item | Evidence/status | Next check |
|---|---|---|
| Long editor message displaces Run controls | Reported observation; fix PR #1271 | Verify the next packaged build |
| Connection dialog spacing | Reported observation; #1270 is in this source base | Recheck narrow and enlarged-text layouts |
| Streaming memory and page tabs | Memory retention reproduced here; [#1272](https://github.com/cozyGarage/BookiE/issues/1272), [#1273](https://github.com/cozyGarage/BookiE/issues/1273) remain open | Gate this fix, qualify native close/RSS and measure #1244; decide paging separately |
| New editor leaves typing in sidebar search | Reported observation, not yet filed or reproduced in this investigation | Focus regression and separate issue/fix |
| Group/tags buttons and welcome-row spacing | Reported observations, not verified against current source | Separate layout regressions |
| Approval overlay/title on old build | Reported old-build behavior; newer behavior not qualified here | Recheck next package |
| One layout shift after approval | Unconfirmed; not reproduced in packaged build | Preserve reproduction if repeated |
| Approval SIGSEGV | One reported occurrence, [#1274](https://github.com/cozyGarage/BookiE/issues/1274) | Symbolize the core and investigate lifecycle separately; no demonstrated relation to this retention cycle |
| Page label versus first id | Unconfirmed | Labels are result ordinals, not primary keys. Use ORDER BY id and clear local sorting before comparison; see #1273 follow-up |
| Light theme, narrow width, scale 2, high contrast and larger text | Untested risks | Installed visual matrix |
| Ctrl+F/filter behavior; edit/paste/insert/delete and failure messages | Unqualified manual flows | Check intended shortcuts and full native interaction paths |
| Empty password/keyring prompt without daemon | Observed in an isolated setup; general behavior unqualified | Separate daemon-absent acceptance; this probe used an isolated unlocked keyring |
| More than ten tabs and very long names | Untested risks | Installed navigation/layout matrix |

## Validation and continuation

Original-base checks passed: preflight, all 87 isolated GTK cases, app all-target Clippy, documentation links, issue ledger and ignored-test inventory. On current base `20ee44f3e`, the updated in-place eviction test also failed at the intended retained-page assertion with the original grid callbacks restored. Current-base preflight and all 88 isolated GTK cases passed. App all-target Clippy initially rejected an unreachable assertion in the new test helper; replacing it with a test panic preserved the assertion, and Clippy passed. The updated lifecycle case was rerun separately after that test-only correction. The two original-implementation contract runs failed at the intended retained-cell and evicted-page assertions. Review was self-review, not independent. No dependency was added.

These are local verification results; Forgejo acceptance has not run. Remaining acceptance includes Forgejo, GitHub checks, native Wayland close measurements, pin/unpin and export ownership, an aggregate UI byte/cell budget decision if measurements require one, and the other retained-resource paths in #1032. #1272 must not be closed as a complete process-memory qualification from this evidence alone.

Later integration note: sandbox validation initially ran a stale SQLite test executable from the shared target directory. The failing executable lacked the new DROP guard diagnostic; the passing driver-only executable contained it. Rebuilding the unchanged driver restored all four workspace-selected cases. [#1281](https://github.com/cozyGarage/BookiE/issues/1281) records the build-cache investigation. The initial SQLite source-defect hypothesis is withdrawn; no SQLite fix is justified by that failure. Final integration checks must use a consistent build snapshot.
