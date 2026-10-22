# Editor bottom panel desktop acceptance, October 22, 2026

Status: the recorded source-built panel passed the focused native desktop matrix. This is not release-package, distro-floor or Forgejo acceptance. Structured clickable error navigation and server NOTICE/PRINT delivery are separate work.

## Checks and findings

- The first regression failed because the editor lacked a persistent Results control. The fixed test also asserts usable initial editor height, unchanged result-widget identity across hiding and exactly one database dispatch.
- All 120 registered isolated GTK tests passed. Four panel regressions cover result retention, chrome-focused maximize/restore, a hidden remembered split and error clearing after success. Existing tests were retained.
- Preflight passed: 2,055 non-GTK unit tests, 2,056 sandbox tests and one Redis cancellation test. The regular app suite passed 720 tests; strict app Clippy passed. These results describe the pre-integration source recorded in the manifest; the PR owns final-head checks after subsequent Linux merges.
- The accessibility/keyboard scenario `results_panel_preserves_query_results_and_keyboard_focus` passed under Xvfb against the source-built binary and a disposable SQLite fixture. Its postcondition proves the INSERT executes once while views and panel visibility change.
- The [manifest](manifest.json) records four native Wayland cases: 1,200 px light/dark and 802 px light/dark with a 20-point SQL font. All passed real Ctrl+J routing from SQL and the result area, maximize/restore, retained values, an actual missing-table error and a real one-second SQLite timeout.
- The dark wide case additionally passed actual pointer dragging, mouse maximize/restore to the secondary SQL editor, hide while maximized with divider preservation and closing a second editor while its results were hidden. The first editor remained usable.

Desktop testing found and corrected two integration defects before this report: initializing the result divider at an unallocated zero height collapsed SQL; the docked sidebar's empty outer overlay slot reserved another column. A zero-width attempt also failed during the sidebar's show animation. The dependency PR #1363 now keeps a one-pixel empty slot and has an allocated regression for the initially-hidden to shown transition. The local panel code uses the same corrected sidebar source.

The desktop used synthetic connections and separate profiles. Only owned application windows, the stale dialog caused by an earlier test abort and matching test-crash popups were closed. No saved user connections or database credentials were used. Each application and private D-Bus session exited after its case.

## Visual evidence

The captured window uses the user's compositor transparency. Images contain only synthetic fixture data.

- [Dark panel after native divider dragging](dark-mouse-dragged.png)
- [Narrow light panel with enlarged SQL text](light-narrow-large-restored.png)
- [Actual SQLite timeout in Errors](dark-mouse-timeout.png)

## Reproduction

Run the registered GTK tier and the installed-style scenario using the current repository scripts. Use system Python when the active Python environment lacks PyAT-SPI. The native [probe](native-acceptance.py) reuses `gtk_safety.py` fixtures from the repository root and accepts `BOOKIE_PANEL_CASE`, `BOOKIE_PANEL_THEME`, `BOOKIE_PANEL_WIDTH`, `BOOKIE_PANEL_FONT` and `BOOKIE_PANEL_POINTER`. It requires a private D-Bus with `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon`, native Wayland, Hyprland's Lua dispatcher API, wtype, grim and system PyAT-SPI. It uses workspace 9 for its owned window and restores the previously active window.

The temporary [pointer probe](native-pointer.c) uses the compositor's advertised virtual-pointer protocol without root. Its header and protocol code were generated with wayland-scanner from the [official wlr virtual-pointer XML](https://github.com/swaywm/wlr-protocols/blob/master/unstable/wlr-virtual-pointer-unstable-v1.xml), then linked with libwayland-client. The probe's absolute geometry is specific to this 1,920 × 1,200 display. It is test evidence, not a product dependency or a general desktop automation API.

Still separate: packaged installation/upgrade, the supported distro floor, broader accessibility/Orca qualification and maintainer Forgejo acceptance. No new claim is made about informational server messages, arbitrary shell execution or SQL error source navigation.

## Final Linux integration

The manifest records the final integration commit and source-built binary digest. After merging Linux's resource fixes, all 121 registered isolated GTK tests and 725 regular app unit tests passed; strict app Clippy and the SQLite no-rerun scenario also passed. All four native cases were repeated on that integrated binary. The pointer case additionally closed a busy hidden query and waited beyond its timeout; its late completion did not replace the first editor's retained result. Final preflight passed: 2,056 non-GTK unit tests, 2,057 sandbox tests and one Redis cancellation test.
