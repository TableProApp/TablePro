# Editor tab closure, October 22

Issue [#1333](https://github.com/cozyGarage/BookiE/issues/1333) records a reported native freeze and missing usable empty state after closing editor tabs. The exact native sequence is not yet isolated. Connection-card layout is separate work in [#1332](https://github.com/cozyGarage/BookiE/issues/1332), including the confirmed popover wrapping case in #1328.

A private D-Bus/Xvfb run on optimized resource candidate `08cf1aa9c` opened four clean editors, closed all of them, activated the empty-state action and successfully queried again. This checks one clean-tab sequence; it does not disprove the native report. The first attempt could not activate the isolated accessibility registry and did not reach the app scenario. The successful attempt selected the D-Bus daemon accessibility implementation and a private runtime directory.

A second scenario restored a disposable SQL file alongside another editor, changed the file text, closed its tab and selected Discard once. It failed on the original code: the file tab remained and the same Save changes alert was present again. The source handler clears row/structure trackers but requeues the ordinary close message while the editor file is still dirty. This is a reproduced modal loop, not proof that every reported freeze has this cause.

The correction gives the confirmed discard a distinct message and resumes closure after the pending-save decision. Clean closure and discard share the existing open-transaction confirmation step, followed by asynchronous editor teardown. It does not mark the original file clean, write the file or detach its association while a later transaction-close decision is pending.

The installed GTK regression keeps the original file unchanged, checks that the intended tab closes, closes the remaining clean tab, physically clicks the empty-state action by its actual screen allocation, and queries again. The original failing artifacts and private test scripts are retained in the persistent local profiling directory. Corrected-build execution, full local validation and acceptance are pending. The broader native report stays open for manual recheck.

## Corrected execution

The corrected optimized build passed the installed regression on the configured 1280×1024 Xvfb display: Discard removed the dirty file tab, the original file remained SELECT 1, the remaining clean tab closed, a physical X11 click on Open SQL editor opened a new tab, and SELECT 9 completed. The [manifest](manifest.json) pins the binary and source patch. All 718 app unit tests and app all-target Clippy also passed. Full preflight and the GTK widget suite remain active.

Two earlier pointer probes were invalid setup checks: AT-SPI screen coordinates returned zero, and then the shared X11 helper could not find an app window on the platform’s default 640×480 Xvfb screen. The installed GTK tier already specifies 1280×1024. Running with that same display and the existing window-relative X11 input helper passed, without weakening the click or query assertions. These setup failures are not classified as an app freeze.

Full preflight and all 105 isolated GTK widget tests subsequently passed, and the existing Save-and-close installed scenario also passed. This validation used the saved resource-candidate base. The close-path source does not depend on those performance changes; an independent Linux-based branch will rerun acceptance before publication. The reported native freeze remains open beyond the reproduced Discard case.

## Independent Linux validation

The fix was copied onto Linux `b150b59ae` without the pending performance train. A fresh optimized build at `15c3a9f9f` passed the same Discard/unchanged-file/final-tab/physical-click/query scenario. All 713 app unit tests and app all-target Clippy passed on this independent source. Its binary hash and scenario result are added to the manifest. The smaller test count reflects the absent performance-train tests, not removed tests. Refreshed preflight and the 103-case GTK widget suite remain active.

The independent branch subsequently passed full preflight and all 103 registered GTK widget tests. The latest manual-testing documentation through `9b8bb2897` was merged afterward; runtime source, tests, scripts, Cargo inputs and workflows compare unchanged against the validated build source. The native notes classify the toolbar event as transient after restart and record a separate hidden-sidebar problem; neither is claimed fixed by this Discard change.
