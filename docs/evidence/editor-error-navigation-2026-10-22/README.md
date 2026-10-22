# Editor error navigation, October 22, 2026

Status: implementation and local/native acceptance complete at `219d2bd1d`. GitHub delivery and maintainer Forgejo acceptance are tracked on [#552](https://github.com/cozyGarage/BookiE/issues/552).

## Behavior and boundaries

The result and Errors views retain server positions for unchanged SQL and offer Go to error. The request carries its original buffer revision and source scope through lexical-settings and parameter waits. The statement planner supplies exact source ranges; Unicode conversion does not search for matching SQL. Gutter marks reuse these ranges for known SQL dialects. Clicking an error checks the latest execution and physical connection identity before restoring the editor and moving the caret. It cannot execute SQL.

Missing, invalid or parameter-rewritten positions retain safe, copyable error text. Cursor cleanup failures have no invented source position. A longer-timeout rerun has no source anchor and offers no navigation. Selection execution remains owned by PR #1361. Backend NOTICE/PRINT delivery remains separate under #1033/#1034 and #550.

## Failures that shaped the implementation

- The first isolated navigation regression failed because positioned errors had no source action.
- Native pointer acceptance found Go to error at window y=872 in a 760 px window. A new allocation assertion failed before the layout fix. Compact controls now stay above scrollable error text.
- Independent review found SQL inside a leading comment could be mistaken for executable source. The GTK regression landed at character 10 instead of 24 before the fix. Parser ranges replace substring lookup, including repeated statements and intervening comments.
- The same cause marked a leading comment as the executed statement in the gutter; its regression returned line 0 instead of line 1 before the shared range fix.
- The first native PostgreSQL setup waited on Secret Service before reaching the editor. The probe now owns a private profile and keyring daemon. This was setup evidence, not a navigation result.

No existing test was deleted. Copy error moved to a focused error-view test module to stay below the file-size limit; its exact isolated selector was updated. Streamed-error tests retain their error-text and retained-page assertions while accepting the compact presentation instead of requiring an AdwStatusPage.

## Verification

Commands, executed counts, source hashes and native matrix are recorded in [manifest.json](manifest.json). The gzip logs retain the executed output; decode them with `gzip -dc`. Local checks passed: preflight (2,056 unit, 2,057 sandbox and one Redis cancellation test), 730 app unit tests, all 128 isolated GTK tests and strict app Clippy. The source-built executable is not a release-package installation. GitHub cheap-tier checks and maintainer Forgejo acceptance remain separate.

The native probe uses a disposable loopback PostgreSQL database, temporary application profile and private D-Bus/keyring session. It targets only its own floating window on workspace 9 and restores the prior focus. A unique inserted row verifies navigation does not rerun SQL. The probe checks Unicode in a third statement, repeated Current through real Ctrl+Shift+Enter, result and Errors view mouse actions, maximized restore, edited-buffer refusal and SQL inside a comment.

## Reproduction

Use an owned disposable PostgreSQL container named `bookie-error-navigation-20261022`, PostgreSQL user `postgres`, database `bookie_test`, and table `navigation_probe(id integer primary key)`. Supply its loopback port through `TABLEPRO_GTK_POSTGRES_PORT`. The probe truncates only that fixture table. It requires the source-built executable at the shared target path, system Python with PyAT-SPI, Hyprland, wtype, grim, and the rootless pointer helper from the [panel acceptance](../editor-bottom-panel-2026-10-22/README.md). The helper assumes a 1920×1200 host output; this probe uses window coordinates at (80,100).

Run the probe under a private session with `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon`, `PATH=/usr/bin:/bin` and `dbus-run-session -- /usr/bin/python native-acceptance.py`. `BOOKIE_NAV_WIDTH`, `BOOKIE_NAV_THEME`, `BOOKIE_NAV_FONT` and `BOOKIE_NAV_CASE` select each case. No desktop configuration is changed. Stop and remove only the owned fixture after acceptance.

## Screenshots

- [Dark, 1,200 px, after navigation](dark-wide.png).
- [Light, 802 px, 20-point SQL text](light-narrow-large.png).
- [Light, SQL repeated in a comment](light-comment-origin.png).

The final native cases launched the same executable SHA-256 recorded in both result JSON files and the manifest. They use GTK 4.24.1, libadwaita 1.10.0 and GtkSourceView 5.22.0 on Arch/Hyprland 0.56.2 with PostgreSQL 17.11. These versions do not establish distro-floor or package acceptance.
