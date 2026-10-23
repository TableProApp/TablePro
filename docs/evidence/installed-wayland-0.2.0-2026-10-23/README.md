# Installed BookiE 0.2.0 native Wayland run, October 23

## Environment and package

`bookie 0.2.0-1` built from `linux` at `1a8ec3247` with `scripts/build-arch-rc.sh` (`dist` profile; `check()` skipped on the final build after one flaky test, see below). `/usr/bin/bookie` SHA-256 began `4fa7870d74810c25`; `pacman -Qkk bookie` reported 28 files with none altered. Arch Linux / Omarchy, Hyprland 0.56.2, GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0, scale 1, dark appearance, native Wayland (`xwayland: false`), window 922×1150.

The app ran with temporary `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME`. Fixtures: PostgreSQL 17.11 in a disposable container with trust authentication (20,000 synthetic `customers` rows with NULL and empty text, JSONB, `numeric(14,2)` and `timestamptz`), and a 300,000-row SQLite file. Input was keyboard (`wtype`) and pointer (`ydotool` with Hyprland cursor positioning); screenshots were taken with `grim` and kept locally. Values were checked against `psql` or `sqlite3`.

An earlier build of `33d12b9b4` panicked on every start (`Gtk has to be initialized before using libadwaita`); [#1468](https://github.com/cozyGarage/BookiE/pull/1468) fixed it before this run.

## Passed

- Connection test reported `TLS handshake failed: server does not support TLS` for Verify Full against a plain server and `Connection ok · 2 table(s) visible` with TLS disabled. The header showed `PostgreSQL 17.11`, matching `show server_version`.
- Grid values matched PostgreSQL: NULL and empty text distinct (ids 10, 1, 11), trailing zero in `133.70`, JSONB key order, `timestamptz` shown in UTC.
- A Unicode edit (`Khách hàng 2 ✓`) saved through a parameterized `UPDATE` with an `IS NOT DISTINCT FROM` check; PostgreSQL stored the exact 18 bytes. A concurrent change to another row was refused at Save and Discard refreshed the row.
- A four-statement script stopped at the failing statement with SQLSTATE 42703 at line 1, column 8; Go to error placed the cursor at line 2, column 8. Running a selection ran only the selected statement.
- Session with `BEGIN`: the update stayed invisible to `psql` (`idle in transaction`), the label showed `transaction open · 1 min` after a minute, and Roll back restored the value with no open transaction left.
- The Audit Log viewer listed the run's operations on the new journal code.
- A WHERE filter returned 149 of 149 rows, matching `count(*)`. Its CSV export equalled PostgreSQL `COPY` for all 149 rows after normalizing boolean, JSON and timestamp formats; the file was created with mode 600.
- F10 opened the main menu; Ctrl+, opened Preferences; the Gruvbox theme applied without restart.
- `SELECT * FROM people` loaded 215,804 of 300,000 rows in 707 ms; process RSS rose from 359,396 to 446,004 KiB (peak 479,044 KiB).
- SIGTERM to the running app ended it with status 143 and no core dump.

## Defects

| Defect | Status |
| --- | --- |
| SQL editor results cut short by the result limit showed no notice until sorted or filtered | [#1492](https://github.com/cozyGarage/BookiE/pull/1492) |
| BookiE and `bookie-agentd` aborted (double panic) when stderr became a broken pipe; symbolized from the core of an earlier run | [#1485](https://github.com/cozyGarage/BookiE/pull/1485) |
| Audit records `rows_affected = 0` for SQL editor writes; the editor shows no affected-row count | [#1486](https://github.com/cozyGarage/BookiE/issues/1486) |
| Completion fetches columns, with an audit record, for every partial table name typed | [#1487](https://github.com/cozyGarage/BookiE/issues/1487) |
| Connection dialog choice rows: not keyboard-activatable, popovers never unparented, selection not marked | [#1488](https://github.com/cozyGarage/BookiE/issues/1488) |
| Save-conflict message has a doubled period and an irrelevant session-state caveat | [#1489](https://github.com/cozyGarage/BookiE/issues/1489) |
| Low-severity UI polish | [#1490](https://github.com/cozyGarage/BookiE/issues/1490) |
| `tablepro-dump` `cancelling_stops_the_tool` failed once with ETXTBSY | [#1491](https://github.com/cozyGarage/BookiE/issues/1491) |

## Limits

- The GTK log reported no accessibility bus; AT-SPI and Orca were not checked. Narrow widths below 922 px, light appearance and high contrast were not run.
- A preference save logged `theme rejected … GSettings migration marker did not persist`. The isolated `XDG_CONFIG_HOME` read GSettings from an empty location while the session's dconf service wrote to the real profile, so this is attributed to the test isolation; the silent failure remains part of [#1490](https://github.com/cozyGarage/BookiE/issues/1490).
- `xdg-desktop-portal-hyprland` crashed repeatedly on the host during the run; it is not part of BookiE.
- Screenshots, the export comparison and the symbolized backtrace stayed in a temporary directory and are not committed.
