# Known limitations of BookiE 0.2

What the application does not do, or does differently from what you might expect, and the bugs we know about. Each entry names its ledger row. Draft of 2026-10-11, for the maintainer; an entry is removed when the row closes.

## Data and values

- **Full-table export is unavailable** (UI-13b / [#553](https://github.com/cozyGarage/BookiE/issues/553)). The current drivers do not have
  a verified snapshot export path, so the application refuses full-table export
  before opening the destination dialog or publishing a file. Export the current
  page or a loaded query result instead. Snapshot export support is planned.
- **Large results are capped and held in memory** (PERF-2, PERF-8 / [#554](https://github.com/cozyGarage/BookiE/issues/554)). Results stop at
  1 million rows, 10 million cells or 64 MiB estimated size. The historical grid
  measurement was about 2.5 times the result memory; #518 now shares immutable
  values with materialized rows, and comparable profiling remains open. Nothing
  is streamed yet.
- **SQL result filters apply only to loaded rows** ([#609](https://github.com/cozyGarage/BookiE/issues/609)). Filter and sort actions are local, show the visible and loaded counts, and do not re-run SQL. Clearing a filter restores loaded rows. Settings carry across reruns of the same statement and pin/unpin while the result remains current or pinned. Selection follows source-row identity when the same materialized result is rerendered; a fresh query resets selection. Settings do not survive an app restart.
- **Long cells are shown as a preview** (PERF-10). A table cell over 8 KiB shows a
  typed preview and its byte count; View Value fetches the whole value by primary
  key. A table without a primary key cannot refetch.
- **Hidden-column projection still needs desktop acceptance** (PERF-9). Merged
  [#384](https://github.com/cozyGarage/BookiE/pull/384) projects hidden non-key
  columns out of the select and refuses full-row copy, row JSON and current-page
  export while those values are unfetched. Distribution Wayland/GNOME acceptance
  remains open.
- **A table without a primary key cannot be deleted from the grid** (TEST-14). There
  is no all-column fallback, by design.
- **ClickHouse ambiguous local times:** a `DateTime64` that falls in a repeated or
  missing daylight-saving hour is shown as undecodable and is never turned into a
  literal, because the instant cannot be known.
- **SQLite real numbers:** negative zero and NaN cannot be bound as parameters.
- **SQLite JSON aggregate output** can differ across system SQLite versions (TEST-25).
- **MongoDB:** browse pages are separate observations, not one point-in-time view (TEST-12); a column with mixed types is read-only; deep unfiltered `_id` keyset browse is fast in local Docker ([#493](https://github.com/cozyGarage/BookiE/pull/493)), but filtered, sorted and keyless deep pages plus installed and network acceptance remain open (PERF-3).
- **MySQL failed batches:** rollback of a failed batch is verified for InnoDB and a Docker matrix that includes MyISAM, MEMORY, CSV, ARCHIVE, `MRG_MyISAM`, BLACKHOLE, Aria and related side effects; optional or vendor engines and package acceptance remain open (B4-11).

## Editing and connections

- **PostgreSQL behind a connection pooler:** PgBouncer in session mode works. In transaction mode it works when the pooler supports prepared statements (PgBouncer 1.21 or newer with `max_prepared_statements` above 0); without that the server answers "prepared statement already exists" and the error now says so. Session features of the editor (`SET`, temporary tables, an open transaction across statements) need session pooling by design.
- **SSH jump chains cannot be edited in the form** (UI-1b / [#548](https://github.com/cozyGarage/BookiE/issues/548)). They connect and run, but editing remains disabled until the complete GTK editor path is implemented and accepted.
- **Reusable SSH profiles cannot be edited** (UI-26).
- **Local socket endpoint differences:** PostgreSQL selects a socket directory plus port; MySQL and MariaDB select the full socket-file path. Both local routes reject TLS and SSH and never fall back to TCP ([#579](https://github.com/cozyGarage/BookiE/issues/579)).
- **SQL Server with Kerberos** has a Samba AD and verified-TLS fixture that passed the Kerberos selectors; Windows AD interoperability and package acceptance remain open (B4-21).
- **DuckDB read-only flat files** need Linux and a writable directory on the same filesystem as the file (the application pins the file through a private link there). A read-only in-memory DuckDB connection is refused.

## Interface

- No code folding or multi-cursor (UI-22, [#629](https://github.com/cozyGarage/BookiE/issues/629)). Split panes are available from the **Split** toolbar button. Vim keys are an opt-in preference; typed vim commands in a running editor are not yet covered by an installed scenario. Preview tabs are temporary and are not restored after restart; tabs you keep are restored (UI-17b). Query history now opens in a docked panel (UI-18).
- The PostgreSQL catalog lists materialized views, routines, triggers, sequences, extensions and roles; a typed activity console is deferred and the activity dialog stays a plain result grid (UI-23).
- Text and JSON values over the preview threshold are read-only in the grid; View Value and Copy value give the full text. Editing them needs the full-value dialog ([#610](https://github.com/cozyGarage/BookiE/issues/610), [#659](https://github.com/cozyGarage/BookiE/issues/659)).
- No server messages (NOTICE, PRINT) and no timing breakdown; timing shows elapsed time only (UI-20, PERF-4 / [#550](https://github.com/cozyGarage/BookiE/issues/550)).
- No foreign-key value picker or estimated row counts (UI-19 / [#549](https://github.com/cozyGarage/BookiE/issues/549)). Enum and set pickers and tab-separated row paste are implemented.
- PostgreSQL schemas can be hidden from the sidebar per connection ([#580](https://github.com/cozyGarage/BookiE/issues/580)); this display filter does not reduce catalog query work. Many-schema performance and restricted-role metadata remain open under B6.
- No database snapshots or restore (SNAP-1 accepted the feature for 0.2.x; build is SNAP-2 to SNAP-4 / [#547](https://github.com/cozyGarage/BookiE/issues/547)).
- Accessibility with Orca, keyboard-only order and high contrast has not been verified (DOC-3).

## Platforms and packaging

- 0.2.0 is tested on Arch Linux with Hyprland as a native Wayland client (Omarchy Arch first). The install, upgrade and rollback pass on the real desktop is pending (PKG-1 / [#574](https://github.com/cozyGarage/BookiE/issues/574)); Xvfb results do not count.
- GNOME on Debian and Ubuntu is not accepted on a real desktop yet (PKG-2), although the packages build and the installed test suite passes in containers.
- The Flatpak build installs and shows a window on a Debian 13 guest, but Flathub submission and screenshots are not done and the package is not offered (PKG-4, PKG-8).
- Windows and macOS are not supported; the application is built for Linux with GTK 4 and libadwaita.

## Known bugs

- **Installed GTK suite is intermittent on Forgejo** (TEST-31 / [#556](https://github.com/cozyGarage/BookiE/issues/556)): accessibility timeouts under capacity pressure, and a separate startup restore abort when GTK logs an `AdwBin` width near minus two billion under `G_DEBUG=fatal-criticals`. It is not yet known whether the layout abort can happen outside that test setup, where GTK only warns.

## Test and CI limits

- The installed GTK suite does not pass reliably on a native Ubuntu 24.04 runner (TEST-28); it passes in the Debian 13 and Ubuntu 24.04 containers.
- About 68 percent of the policy crate's and 81 percent of the core crate's mutations were caught by their own tests when measured at `0d21eb6d4` (2026-10-11); later survivor triage is in the [B4 mutation triage](evidence/b4-mutation-triage-2026-10-12) and the figure has not been re-measured; the survivors are listed in the [mutation reports](evidence/test-quality-2026-10-11/policy-mutants.md) (TEST-32).
