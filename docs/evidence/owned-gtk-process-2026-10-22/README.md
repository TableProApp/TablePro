# Owned GTK process checks, October 22, 2026

Status: implementation and local validation complete. GitHub and maintainer Forgejo acceptance remain on [#1298](https://github.com/cozyGarage/BookiE/issues/1298).

## Defect and change

The old memory helper scanned all matching application executable names. The second-launch scenario used the same discovery and read the selected process environment. If a desktop instance appeared first, the harness could sample or relaunch that instance instead of its isolated fixture. This confirms an ambiguity, not that any earlier published profile selected the wrong process.

Startup now retains its exact subprocess, expected executable and a copy of the supplied fixture environment. Memory sampling and second launch verify liveness, Linux process birth ticks and the executable device/inode before and after their work. Replacement of the executable at the same path is refused. Neither path enumerates processes or reads process environments. Stop clears matching ownership; restart records the new child. Profile rows carry the fixture PID and start ticks. The standing contract is in [testing](../../testing.md).

## Regression and local acceptance

The failing-first boundary tests supply desktop process 101 and fixture process 202. The old code returns RSS 111 instead of 222 and the desktop sentinel environment instead of the supplied fixture environment. These are synthetic fixtures; the reproducer reads no real process environment. [before.log.gz](before.log.gz) preserves both failures.

All 18 focused process tests pass, including the four existing stderr-capture/startup cleanup tests. The new cases cover both enumeration orders, environment copying, exited and reused PIDs, changed executable identity, disappearance, exit during sampling/relaunch, and a real owned child. The 14 ownership/boundary tests also pass under Python optimization; lifetime guards remain active. No existing test was removed or weakened.

Final preflight passed: 359 harness tests, 2,056 unit tests, 2,059 sandbox tests and the Redis cancellation regression. The Debian archive sub-check was unavailable because local `dpkg-deb` is absent. No Rust product source or dependency changed.

Three targeted GTK scenarios passed with the source-built debug executable on Arch Linux, isolated X11/Xvfb/Cairo and disposable SQLite fixtures:

- `a_second_launch_raises_the_window_and_exits_cleanly`.
- `restart_with_an_untouched_editor_restores_without_layout_criticals`.
- `profile_large_result_in_the_grid`, 1,000 rows and four scroll steps.

The executable was copied to a private acceptance path immediately after Cargo built it. Its recorded hash was checked after all scenarios. Rust source matches Linux `f22a4905ddfe4cff74fd37247d4d028ac9c534e3`; the changed Python harness is pinned separately. This prevents later shared-target builds from replacing the accepted executable. [binary.json](binary.json), [profile output](verified-profile.jsonl) and the three scenario result records preserve the evidence.

The small profile is an ownership/measurement-path smoke test, not a performance benchmark or a new application memory qualification. Full installed GTK, native Wayland and packaging acceptance remain with the maintainer Forgejo gate. No Forgejo run or merge was started. Test processes, displays, buses and temporary SQLite profiles exited through the harness cleanup; no existing database container was changed.

## Reproduction

Run the pure regressions without a display:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_gtk_*process*.py'
python3 -O -m unittest discover -s scripts/tests -p test_gtk_owned_process.py
```

Use the installed GTK harness with `TABLEPRO_GTK_BINARY` set to a known executable and `TABLEPRO_GTK_SCENARIO` set to the three names above. For the profile case set `TABLEPRO_PROFILE_ROWS=1000`, `TABLEPRO_PROFILE_SCROLL_STEPS=4` and `TABLEPRO_PROFILE_OUT` to an owned output file. Record the executable checksum before and after the run. Retain the private profile and display isolation provided by `scripts/test-gtk-safety.sh`.

Compressed logs retain complete command output. [manifest.json](manifest.json) records final source and artifact hashes. The separate source/lifecycle/security self-review found no remaining defect; it was not an independent review.
