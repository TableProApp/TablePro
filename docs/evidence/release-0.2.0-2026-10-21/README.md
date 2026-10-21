# 0.2.0 release qualification, October 21

## Source and packaging

Tag `linux-v0.2.0` identifies `bd31a1d8b3dc83200c324b9f37fa83f3660d8aab`. The dated changelog contains the 0.2.0 notes. The [candidate workflow](https://github.com/cozyGarage/BookiE/actions/runs/39671354230) passed version checks and Debian, Arch, AppImage and Flatpak builds. The [tag workflow](https://github.com/cozyGarage/BookiE/actions/runs/39674240261) is a separate build; candidate hashes below do not identify its final assets. Publication is pending at this checkpoint.

The preceding accepted runtime baseline passed all 29 Forgejo jobs; see the [PostgreSQL gate repair](../postgres-gate-repair-2026-10-21/README.md). The release-tip change only removes a duplicated changelog entry.

## Candidate package checks

- Arch archive SHA-256: `221bed24efa57231473022dab1f8132c1f6918b133bb71378c855a7daaa24372`. Its supplied checksum and `validate-arch-package.sh` passed.
- Extracted Arch application SHA-256: `d45556da8b994688987157cfc74e1d58e39d10894e11b157fc8077b2ccfbb386`.
- AppImage SHA-256: `428660490de7bf431ac85b683c011b8948825b0cbca3ad6e619a5de54b3afb4d`. Its supplied checksum and extraction passed.
- A disposable Arch container installed the candidate through pacman, ran the agent help command and removed the package successfully. This does not establish host installation, desktop integration or upgrade preservation.

## Functional checks

The extracted Arch application passed these fourteen existing scenarios under private D-Bus and Xvfb, using synthetic SQLite data: connection form controls; malformed-statement refusal; dismissed approval denial; named-parameter binding; primary-key-ordered CSV export; JSON export preservation; pinned-result ordering; find/replace; complete-value inspection; persisted cell editing; multiline paste preservation; narrow toolbar reachability; value filtering; refusal of paste beyond loaded rows.

A native Wayland attempt passed malformed-statement refusal and pinned-result ordering. Five dialog scenarios could not reach their controls. Hyprland reported the application mapped on DP-2 while that monitor had DPMS off. These attempts are inconclusive for rendered behavior, not confirmed product defects. Native appearance, light/dark screenshots and installed host acceptance remain unverified.

## CPU and memory

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

A longer replacement/close series, final-asset provenance and installed host acceptance remain pending. This record does not claim the complete manual verification matrix passed.
