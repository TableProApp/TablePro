# Installed BookiE 0.2.0 native Wayland check

## Environment and package

The installed package was `bookie 0.2.0-1` on Arch Linux / Omarchy with Hyprland 0.56.2, GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0 and display scale 1. The app used native Wayland (`xwayland: false`). Package build inputs identify release commit `bd31a1d8b3dc83200c324b9f37fa83f3660d8aab` (`linux-v0.2.0`). `/usr/bin/bookie` SHA-256 was `d45556da8b994688987157cfc74e1d58e39d10894e11b157fc8077b2ccfbb386`. `pacman -Qkk bookie` reported 28 files with no altered files.

The repository checkout was `linux` at `faea584d1c151295583840c2af2d2467e7647c21`; this identifies the review context, not the installed binary source. The release source identity is recorded separately above.

## Observations

- The welcome screen and PostgreSQL connection form rendered. A local PostgreSQL 16.14 test container did not support TLS. The app's default Verify Full test correctly failed; selecting Disabled made the connection test pass. The test server bound to loopback only.
- A synthetic table with two rows showed primary-key marking, NULL separately from empty text, booleans, exact `numeric(20,4)` values, multiline text, Unicode edits and ellipsized long text. A SQL `UPDATE ... RETURNING` wrote and displayed the changed value. Screenshots: `/tmp/bookie-installed-gtk-2026-10-21/postgres-connect-form.png`, `postgres-connect-result.png`, `postgres-grid-dark.png`, `table-filter-dark.png`.
- With the disposable PostgreSQL server stopped, retrying the table read showed “Couldn't load rows” and “The operation timed out.” That was the expected result for the deliberately unavailable test server. Clicking the database-switcher icon during the outage showed a narrow “Loading…” row with one letter per line. This is a visual defect: the loading text should remain readable in the switcher popover. The implementation sets a 280-pixel minimum content width, but the captured popup did not honor it. User-provided screenshot: `/tmp/codex-clipboard-whIFMb.png`.
- At 922 logical pixels wide, the 280-pixel sidebar remained open and reduced the content area. No literal sidebar/editor overlap appeared in the captured state. At 802 pixels, the sidebar collapsed automatically and Run/Split remained visible. With the row inspector hidden, the grid stayed usable and long values were ellipsized. At 1920 pixels, all six test columns were visible. Screenshots: `editor-dark-922px.png`, `editor-narrow-802.png`, `grid-narrow-802-no-inspector.png`, `editor-results-dark-full.png` in the temporary directory above. These observations do not rule out overlap in another view or with different content.
- The appearance selector was changed from System to Light to compare rendering. A later user-provided screenshot shows BookiE in dark appearance, but does not establish whether the selected preference is System or Dark. The preference state was not read back, so its restoration remains unverified. The screenshot set does not cover high contrast, larger text, mixed-scale monitors or Orca.
- The temporary PostgreSQL container was stopped after the value and write checks. BookiE displayed “Connection lost — reconnecting”, which is expected for that stopped test database. A later user-provided screenshot confirms the app window remained open. No BookiE core dump or matching app journal entry was found. The saved “Codex disposable PostgreSQL” profile may remain in the app, and its removal was not verified.

## Resource sample

One synthetic query returned 100 rows, each containing an 8 KiB generated text value (`repeat('x', 8192)`). The result appeared in about 0.67 seconds. Sampling only the BookiE PID at 100 ms intervals recorded RSS from 189,648 KiB before the query to 189,764 KiB at the end, and 0.76 seconds of CPU time over the sample interval (about 113% of one core). This is a single warm-session sample on a local container. It is not a cold-start, sustained-load, large-dataset, or comparative footprint benchmark.

## Coverage limits

The 93-scenario installed GTK run under Xvfb/AT-SPI is recorded separately in [the 2026-10-21 GTK evidence](../installed-gtk-0.2.0-2026-10-21/README.md). This native run did not cover keyboard-only navigation across every dialog, clipboard round trips, Orca announcements, high contrast, SSH, other database engines, reconnect recovery after a live server restart, window restart restoration, or long-duration memory behavior. The saved connection cleanup and System appearance restoration remain unverified. Screenshots and raw profiles are temporary under `/tmp/bookie-installed-gtk-2026-10-21/` and are not committed.
