# X11 popup targeting

Follow-up for [issue 556](https://github.com/cozyGarage/BookiE/issues/556), based on Linux `3b6ef5f44`. The keyboard helper already excludes override-redirect windows. The pointer and resize helpers still selected the last mapped root child at least 800 by 600 pixels, including large transient popups.

Two boundary regressions exercise the actual helpers with an application at (100, 50) and an overriding popup at (400, 300). Before the repair, resize selected the popup and the requested click landed at (410, 339), rather than (110, 89). Both regressions pass after excluding override-redirect windows. Existing size thresholds and the 19-pixel coordinate calibration are preserved.

Run `python3 -m unittest discover -s scripts/tests -p test_gtk_click_offset.py` for all seven input-helper tests. The X11 boundary is mocked in these regressions; they check emitted window operations and coordinates rather than requiring a desktop.

A separate disposable Xvfb experiment created actual application and override-redirect windows through libX11. The [observation](native.json) confirms that only the application resized and the pointer reached its intended root coordinates. This is a synthetic window experiment, not proof that a particular installed GTK scenario previously encountered a popup this large.

Issue 556 stays open: this repair does not prove ten successful gate runs or eliminate all accessibility timeouts. Native Wayland behavior is unchanged. The full script harness passed all 396 Python tests (Debian package validation skipped because `dpkg-deb` is unavailable). The [installed pointer scenario](installed-pointer.json) passed without retries in 4.013 seconds, and the sidebar resize scenario passed without retries in 5.613 seconds, using the recorded existing optimized artifact. That artifact was not rebuilt from this branch; the run validates the revised helper against the app, not full current-head application behavior. Full [preflight](validation.json) passed. A separate self-review found no additional issue in this focused change; independent review was not performed. Forgejo acceptance remains pending.
