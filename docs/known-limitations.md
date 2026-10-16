# Known limitations of BookiE 0.2

What the application does not do, or does differently from what you might expect, and the bugs we know about. Entries link to their owning issue, decision or evidence when one exists. Reviewed 2026-10-16.

## Data and values

- **Full-table export is unavailable** ([ADR 0014](decisions/0014-full-table-export-snapshot.md)). The current drivers do not have
  a verified snapshot export path, so the application refuses full-table export
  before opening the destination dialog or publishing a file. Export the current
  page or a loaded query result instead. A per-engine consistent export path is
  an unselected future candidate; database snapshots for backup and restore are
  a separate feature accepted for 0.2.x ([ADR 0015](decisions/0015-database-snapshots.md)).
- **Large results still have materialization limits** (PERF-2, PERF-8 / [#554](https://github.com/cozyGarage/BookiE/issues/554)). Materialized
  results stop at 1 million rows, 10 million cells or 64 MiB estimated size.
  Single-statement PostgreSQL `SELECT`s in the SQL editor now stream cursor
  pages through Core and PolicyGuard, retaining at most four pages of up to
  5,000 rows each. That cache is bounded by page and row count, not by cell
  bytes. A synthetic profile with four pinned results and one active stream
  reached 1,325 MiB RSS; see the [profile evidence](evidence/stream-retention-synthetic-2026-10-16/README.md).
  This does not measure normal queries or the complete process ceiling. Other
  engines and unsupported statement shapes remain materialized.
  The historical grid measurement was about 2.5 times the result memory; #518
  now shares immutable values with materialized rows, and comparable profiling
  remains open (ADR 0011).
- **SQL result filters apply only to loaded rows** ([#609](https://github.com/cozyGarage/BookiE/issues/609)). Filter and sort actions are local, show the visible and loaded counts, and do not re-run SQL. Clearing a filter restores loaded rows. Settings carry across reruns of the same statement and pin/unpin while the result remains current or pinned. Selection follows source-row identity when the same materialized result is rerendered; a fresh query resets selection. Settings do not survive an app restart.
- **Long cells are shown as a preview** (PERF-10). Values over 8 KiB show a typed
  preview and byte count. View Value and Copy Value use the full value, including
  pending edits and drafts. Browse-table values are refetched by primary key; a
  table without one cannot refetch.
- **Hidden-column projection still needs desktop acceptance** (PERF-9). Merged
  [#384](https://github.com/cozyGarage/BookiE/pull/384) projects hidden non-key
  columns out of the select and refuses full-row copy, row JSON and current-page
  export while those values are unfetched. Installed Arch/Hyprland Wayland
  acceptance remains open; Debian/GNOME acceptance follows after 0.2.0.
- **A table without a primary key cannot be deleted from the grid** (TEST-14). There
  is no all-column fallback, by design.
- **ClickHouse ambiguous local times:** a `DateTime64` that falls in a repeated or
  missing daylight-saving hour is shown as undecodable and is never turned into a
  literal, because the instant cannot be known.
- **SQLite real numbers:** negative zero and NaN cannot be bound as parameters.
- **SQLite JSON aggregate output** can differ across system SQLite versions (TEST-25).
- **CSV import does not map SQL Server IDENTITY columns.** PostgreSQL, MySQL/MariaDB and SQLite can import explicit auto-increment values when mapped. SQL Server identity columns and generated columns remain database-owned ([#634](https://github.com/cozyGarage/BookiE/issues/634)).
- **Unzoned PostgreSQL `timestamptz` CSV values** are currently interpreted as UTC. [PostgreSQL](https://www.postgresql.org/docs/current/datatype-datetime.html) normally interprets unzoned timestamp input in the session time zone; the import rule is awaiting a decision ([#857](https://github.com/cozyGarage/BookiE/issues/857)). Include an explicit zone in the CSV to avoid ambiguity.
- **MongoDB:** browse pages are separate observations, not one point-in-time view (TEST-12); a column with mixed types is read-only. Compatible `_id` pages can use keyset seeking ([#493](https://github.com/cozyGarage/BookiE/pull/493)), and supported sort requests run server-side ([#837](https://github.com/cozyGarage/BookiE/pull/837)). Sorted pages outside the compatible `_id` keyset path and keyless deep pages still use offset pagination. Installed and representative-network acceptance remain open (PERF-3 / [#555](https://github.com/cozyGarage/BookiE/issues/555)).
- **MySQL failed batches:** rollback of a failed batch is verified for InnoDB and a Docker matrix that includes MyISAM, MEMORY, CSV, ARCHIVE, `MRG_MyISAM`, BLACKHOLE, Aria and related side effects; optional or vendor engines and package acceptance remain open (B4-11).

## Editing and connections

- **PostgreSQL behind a connection pooler:** PgBouncer in session mode works. In transaction mode it works when the pooler supports prepared statements (PgBouncer 1.21 or newer with `max_prepared_statements` above 0); without that the server answers "prepared statement already exists" and the error now says so. Session features of the editor (`SET`, temporary tables, an open transaction across statements) need session pooling by design.
- **SSH jump chains cannot be edited in the form** (UI-1b / [#548](https://github.com/cozyGarage/BookiE/issues/548)). They connect and run, but editing remains disabled until the complete GTK editor path is implemented and accepted.
- **Reusable SSH profiles cannot be edited** (UI-26).
- **Local socket endpoint differences:** PostgreSQL selects a socket directory plus port; MySQL and MariaDB select the full socket-file path. Both local routes reject TLS and SSH and never fall back to TCP. Connection URLs cannot express local socket endpoints; configure them in the form or import a connection bundle ([#579](https://github.com/cozyGarage/BookiE/issues/579)). An imported MySQL connection with a directory-style `socket_dir` can still pass validation even though MySQL requires a socket-file path ([#638](https://github.com/cozyGarage/BookiE/issues/638)).
- **SQL Server with Kerberos** has a Samba AD and verified-TLS fixture that passed the Kerberos selectors; Windows AD interoperability and package acceptance remain open (B4-21).
- **A timed-out SQL Server query cannot be stopped on the server yet.** Its outcome is unknown and BookiE retires that connection or session; Tiberius 0.13 has a cancellation API, but BookiE has not verified it against the session lifecycle (B4-23 / [#850](https://github.com/cozyGarage/BookiE/issues/850)).
- **DuckDB read-only flat files** need Linux and a writable directory on the same filesystem as the file (the application pins the file through a private link there). A read-only in-memory DuckDB connection is refused.

## Interface

- Multi-cursor editing is not available (UI-22 / [#552](https://github.com/cozyGarage/BookiE/issues/552)). Split panes and SQL code folding are available. Vim keys are an opt-in preference; typed vim commands in a running editor are not yet covered by an installed scenario. Preview tabs are temporary and are not restored after restart; tabs you keep are restored (UI-17b). Query history now opens in a docked panel (UI-18).
- The PostgreSQL catalog lists materialized views, routines, triggers, sequences, extensions and roles; a typed activity console is deferred and the activity dialog stays a plain result grid (UI-23).
- Text and JSON values over the 8 KiB preview threshold can be edited in the full-value dialog up to 1 MiB. Invalid JSON cannot be staged; SQL NULL, empty text, JSON `null`, and text `null` remain separate values. View Value and Copy Value expose the full value. Values over 1 MiB remain read-only.
- No server messages (NOTICE, PRINT) and no timing breakdown; timing shows elapsed time only (UI-20, PERF-4 / [#550](https://github.com/cozyGarage/BookiE/issues/550)).
- No foreign-key value picker or estimated row counts (UI-19 / [#549](https://github.com/cozyGarage/BookiE/issues/549)). Enum and set pickers and tab-separated row paste are implemented.
- PostgreSQL schemas can be hidden from the sidebar per connection ([#580](https://github.com/cozyGarage/BookiE/issues/580)); this display filter does not reduce catalog query work. Many-schema performance and restricted-role metadata remain open under B6.
- No database snapshots or restore (SNAP-1 accepted the feature for 0.2.x; build is SNAP-2 to SNAP-4 / [#547](https://github.com/cozyGarage/BookiE/issues/547)).
- Accessibility is not fully verified with Orca, keyboard-only navigation or high contrast (DOC-3). Concrete gaps are tracked in [#658](https://github.com/cozyGarage/BookiE/issues/658): some connection controls and text fields are missing names or actions in the accessibility tree, and grid menu items are not exposed consistently.

## Platforms and packaging

- The 0.2.0 desktop target is Arch Linux / Omarchy under Hyprland as a native Wayland client. Installed package acceptance, including install, upgrade and rollback, remains pending (PKG-1 / [#574](https://github.com/cozyGarage/BookiE/issues/574)); Xvfb results do not count.
- Native Debian and Ubuntu GNOME desktop acceptance remains open for the later PKG-2 phase, although the packages build and the installed test suite passes in containers.
- Flatpak is not offered. Flathub submission and screenshots remain open (PKG-4, PKG-8); the earlier manual install and launch checks are recorded in the [platform guide](platforms.md#flathub).
- Windows and macOS are not supported; the application is built for Linux with GTK 4 and libadwaita.

## Known bugs

- **Several UI details remain inconsistent** ([#660](https://github.com/cozyGarage/BookiE/issues/660)): text and bytea NULL values render differently, Structure tab chevrons look inverted, and the catalog kind selector can shift the search field.
- **PostgreSQL `VOID` results are shown as undecodable** ([#660](https://github.com/cozyGarage/BookiE/issues/660)); they should render as empty values.
- **Two installed launches were reported to abort inside BookiE** ([#666](https://github.com/cozyGarage/BookiE/issues/666)); the cause remains under investigation.
- **Installed GTK suite is intermittent on Forgejo** (TEST-31 / [#556](https://github.com/cozyGarage/BookiE/issues/556)): the startup restore layout abort was fixed in [#821](https://github.com/cozyGarage/BookiE/pull/821). Intermittent failures remain under investigation; recent failures include an application shutdown with a bad exit status after the scenarios passed. The required consecutive full-run evidence has not been met.

## Test and CI limits

- The installed GTK suite does not pass reliably on a native Ubuntu 24.04 runner (TEST-28); it passes in the Debian 13 and Ubuntu 24.04 containers.
- Mutation results are tied to their source SHA; use the latest [TEST-2 / #559](https://github.com/cozyGarage/BookiE/issues/559) report for survivor and timeout status. Expected-value provenance is tracked separately by [TEST-32](oracle-review.md).
