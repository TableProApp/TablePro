# 0.2.0 release qualification, October 21

## Source and packaging

Tag `linux-v0.2.0` identifies `bd31a1d8b3dc83200c324b9f37fa83f3660d8aab`. The dated changelog contains the 0.2.0 notes. The [candidate workflow](https://github.com/cozyGarage/BookiE/actions/runs/39671354230) passed version checks and Debian, Arch, AppImage and Flatpak builds. The [tag workflow](https://github.com/cozyGarage/BookiE/actions/runs/39674240261) is a separate build; candidate hashes below do not identify its final assets. All four tag package jobs subsequently passed. Draft creation failed while looking for `bookie.pot` instead of `translations/bookie.pot`; [#1300](https://github.com/cozyGarage/BookiE/issues/1300) and [#1301](https://github.com/cozyGarage/BookiE/pull/1301) own recovery. Recovery [run 39683269960](https://github.com/cozyGarage/BookiE/actions/runs/39683269960) subsequently succeeded after #1301 merged. The draft contains all six checksummed assets, and GitHub attestations verified for the four main package formats. Attestations identify finalizer workflow commit `faea584d1c151295583840c2af2d2467e7647c21`; the Arch build-input manifest separately identifies original package source `bd31a1d8b`. Public publication remains pending at this checkpoint.

The preceding accepted runtime baseline passed all 29 Forgejo jobs; see the [PostgreSQL gate repair](../postgres-gate-repair-2026-10-21/README.md). The release-tip change only removes a duplicated changelog entry.

## Candidate package checks

- Arch archive SHA-256: `221bed24efa57231473022dab1f8132c1f6918b133bb71378c855a7daaa24372`. Its supplied checksum and `validate-arch-package.sh` passed.
- Extracted Arch application SHA-256: `d45556da8b994688987157cfc74e1d58e39d10894e11b157fc8077b2ccfbb386`.
- AppImage SHA-256: `428660490de7bf431ac85b683c011b8948825b0cbca3ad6e619a5de54b3afb4d`. Its supplied checksum and extraction passed.
- A disposable Arch container installed the candidate through pacman, ran the agent help command and removed the package successfully. This does not establish host installation, desktop integration or upgrade preservation.

The tag-run Arch archive checksum passed: `3a9d10c2e22930aba86d8c828b7a25a2c1cf35386c7b92d8a0fd88c52ddc301e`. Its extracted application is byte-for-byte identical to the profiled candidate binary above. The package archives differ, so archive checksums must not be interchanged. This establishes binary identity; host installation and desktop integration remain separate checks.

## Functional checks

The extracted Arch application passed these fourteen existing scenarios under private D-Bus and Xvfb, using synthetic SQLite data: connection form controls; malformed-statement refusal; dismissed approval denial; named-parameter binding; primary-key-ordered CSV export; JSON export preservation; pinned-result ordering; find/replace; complete-value inspection; persisted cell editing; multiline paste preservation; narrow toolbar reachability; value filtering; refusal of paste beyond loaded rows.

A native Wayland attempt passed malformed-statement refusal and pinned-result ordering. Five dialog scenarios could not reach their controls. Hyprland reported the application mapped on DP-2 while that monitor had DPMS off. These attempts are inconclusive for rendered behavior, not confirmed product defects. The connection-form structure passed after moving only the owned application to the powered-on HDMI display. A screenshot then showed the desktop password lock screen, so native keyboard/screenshot testing was stopped. Native appearance, light/dark screenshots and installed host acceptance remain unverified. A subsequent overlapping private-runtime attempt also produced inconclusive accessibility failures; it is excluded.

## CPU and memory

The [environment record](environment.json) identifies the workstation and native libraries. Standard GTK-script SQLite runs use a 1280×1024 Xvfb screen. The custom file and PostgreSQL probes initially inherited the installed xvfb-run default of 640×480; their narrow-layout costs must not be treated as normal-width results.

Measurements use the exact launched process, executable verification and a PID file. A 0.5-second sampler records RSS, PSS, private memory, CPU time and available host memory. The owned app is stopped at 4 GiB RSS or below 8 GiB available host memory. Raw captures remain outside the repository in the dated local release-artifact directory.

The 100,000-row, six-column SQLite query passed load and scroll checks: first-result observation 1.11 seconds, engine status 403 ms, peak observed RSS 266.9 MiB. The complete 73.8-second capture includes 2,000 scripted scrollbar updates, accessibility traversal, Cairo rendering and perf sampling. It is not an idle-CPU or native-Wayland benchmark. SQLite materializes this result; this does not establish PostgreSQL streaming retention.

Perf captured approximately 57 CPU seconds with no lost samples. Individual samples include GTK label updates, text shaping, GObject operations and allocation; the stripped application prevents complete application-level attribution. These samples do not isolate a single root cause.

A separate 10,000-row heaptrack run completed its query and scroll observations: peak allocated heap 72.04 MB, peak RSS including instrumentation 269.37 MB. The harness marked shutdown failed because its wrapper returned 143 after the requested SIGTERM. The remaining 70.42 MB reported at termination represents outstanding allocations; it is not a demonstrated leak. Repeated replacement/close cycles and graceful-shutdown captures remain necessary. An earlier attempt injected heaptrack into an exec wrapper and stalled at startup; it was stopped and excluded.

## Follow-up defects

- [#1297](https://github.com/cozyGarage/BookiE/issues/1297): the Arch rebuild-test wrapper omits the required release date. The release workflow supplies it and is unaffected.
- [#1299](https://github.com/cozyGarage/BookiE/issues/1299): an 8 MiB single-line SQL file reached 1,220.72 MiB RSS / 1,181.50 MiB PSS. The file opened and no safety stop fired; allocation attribution and repeated-close behavior remain open.
- [#1298](https://github.com/cozyGarage/BookiE/issues/1298): existing GUI profiling helpers can select an unrelated application process. The independent sampler above pins the launched process.

The corrected file-chooser probe opened an 8 MiB SQL file and an 8 MiB single comment line; a file of 8 MiB plus one byte was refused. The first chooser attempt did not activate its path entry and never opened the file; it is excluded from performance results. The 8 MiB multi-line run reached 329.8 MiB RSS and returned to zero measured CPU during its final observation window. Exact per-run peaks and CPU totals are in [candidate measurements](candidate-measurements.json). These short runs do not establish prolonged editing or leak freedom.

PostgreSQL 17.11 streaming passed two cycles of a long generated query, cancellation, replacement and editor close. Each query ran for 35 seconds before cancellation. An independent `pg_stat_activity` observer confirmed the owned query was active beforehand and absent after cancellation in both cycles. Connected-idle RSS was 166.4 MiB; the first close measured 182.6 MiB and the second 195.8 MiB. Peak RSS was 197.5 MiB across the 108.5-second capture, with about 2.86 CPU seconds. Two cycles do not establish a plateau or prove leak freedom. The statement includes `pg_sleep(0.0001)`, so its low CPU does not represent a saturated stream. The fixture container was stopped after the test.

A subsequent SQLite query requested one million rows but returned only the first 120,019 under the decoded-result budget. Peak RSS was 262.4 MiB. This is not a full one-million-row materialization result. The UI probe inferred the shortened range; explicit warning acceptance was not checked in that run.

A saturated PostgreSQL series at 640×480, with stderr written directly to a file, completed 10,000- and 100,000-row runs and three one-million-row runs. Each million-row view reported 200 pages and retained rows 980,001–1,000,000. These counters do not establish successful terminal completion: a subsequent normal-width capture exposed a schema error after fully populated pages. The series included a 50,000-row query with 8,193-byte values; its terminal UI status was not captured by the narrow selector, so that case is not qualified as a successful result. Peak RSS across the series was 509.5 MiB; after the final narrow-result close it was about 403.5 MiB. Allocation ownership and a long-run plateau remain unproven.

The first saturated attempt stalled its unread stderr pipe when narrow-layout warnings filled it; it is excluded. This is the already-recorded harness limitation in [#1279](https://github.com/cozyGarage/BookiE/issues/1279), not a demonstrated application crash. File-backed stderr allowed the subsequent series to complete. CPU totals include layout work and controlled accessibility checks. Perf stopped on SIGINT in the later captures; no successful profiler exit is claimed for those runs.

The normal-width capture exposed a terminal schema error for exact page multiples, including 10,000 and 100,000 rows. [#1302](https://github.com/cozyGarage/BookiE/issues/1302) records the reproduction and inconsistent type-name casing in populated versus empty-page metadata. The earlier narrow selector did not capture that error. The completed normal-width series peaked at 512.59 MiB RSS / 474.79 MiB PSS and consumed about 64.96 CPU seconds over 109.71 seconds. This is similar to the narrow series, so narrow-layout warnings alone do not explain the streaming CPU cost. All six result views exposed terminal schema failure, including the wide-value case. These runs characterize the failing path, not successful streaming acceptance. Longer replacement/close series, allocation attribution and final-asset provenance remain pending. The maintainer will perform native visual and laptop acceptance; the remote workstation desktop is locked. This record does not claim the complete manual verification matrix passed.

## Isolated long-line layout reproduction

A [minimal GTK reproducer](long-line-widget.py), with no BookiE code, reached 1,186.91 MiB RSS / 1,157.01 MiB PSS using GtkSourceView for one 8 MiB comment line. Plain GtkTextView reached 1,155.41 MiB RSS / 1,128.30 MiB PSS. Splitting approximately the same text into 80-byte lines reduced the GtkSourceView peak to 150.02 MiB RSS / 116.81 MiB PSS. All three exited normally under Xvfb/Cairo. This isolates a substantial allocation cost to GTK text layout; it does not establish a leak or remove the need for application mitigation.

The script requires PyGObject, GTK4 and GtkSourceView5. Set `BOOKIE_PROBE_PIDFILE` to an owned temporary PID file and run under private D-Bus/Xvfb with argument `source-line`, `source-multiline` or `gtk-line`. It creates a synthetic buffer, presents it for seven seconds and destroys the window. Preflight was running concurrently, so CPU comparisons are excluded.

The [terminal cursor metadata correction](../postgres-terminal-metadata-2026-10-22/README.md) records the failed shared-casing attempt and the cursor-local fix that preserves the existing zero-row contract.
