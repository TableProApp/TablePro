# Known limitations of BookiE 0.2

Documented application limits, behavior differences and known defects. Entries link to their owning issue, decision or evidence when one exists. Issues own current work and acceptance status; this page records user-visible behavior.

## Data and values

- **Full-table export is unavailable** ([ADR 0014](decisions/0014-full-table-export-snapshot.md)). The current drivers do not have
  a verified snapshot export path, so the application refuses full-table export
  before opening the destination dialog or publishing a file. Export the current
  page or a loaded query result instead. A per-engine consistent export path is
  an unselected future candidate; database snapshots for backup and restore are
  a separate feature with an accepted design and no release target ([ADR 0015](decisions/0015-database-snapshots.md)).
- **Large results still have materialization limits** (PERF-2, PERF-8 / [#554](https://github.com/cozyGarage/BookiE/issues/554)). Materialized
  results stop at 1 million rows, 10 million cells or 64 MiB estimated size.
  Single-statement PostgreSQL `SELECT`s in the SQL editor now stream cursor
  pages through Core and PolicyGuard, retaining at most four pages of up to
  5,000 rows each. Previous/Next controls navigate only retained pages. The
  received-row summary identifies the retained range when earlier rows have
  been discarded; those rows cannot be revisited without running the query
  again. Row ranges are positions in the result, not database row identifiers.
  That cache also retains at most 64 MiB of estimated row storage, except
  that the newest page is always kept even if it alone exceeds the budget.
  Incoming decoding, concurrent snapshots, pins, widgets and allocator retention
  remain outside this cache estimate. A synthetic profile with four pinned results and one active stream
  reached 1,325 MiB RSS; see the [profile evidence](evidence/stream-retention-synthetic-2026-10-16/README.md).
  This does not measure normal queries or the complete process ceiling. Other
  engines and unsupported statement shapes remain materialized.
  The historical grid measurement was about 2.5 times the result memory; #518
  now shares immutable values with materialized rows. Further comparable
  profiling is tracked with PERF-2/8 (ADR 0011).
- **SQL result filters apply only to loaded rows** ([#609](https://github.com/cozyGarage/BookiE/issues/609)). Filter and sort actions are local, show the visible and loaded counts, and do not re-run SQL. Clearing a filter restores loaded rows. Settings carry across reruns of the same statement and pin/unpin while the result remains current or pinned. Selection follows source-row identity when the same materialized result is rerendered; a fresh query resets selection. Settings do not survive an app restart.
- **File exports use text markers for undecodable cells** ([#883](https://github.com/cozyGarage/BookiE/issues/883)). CSV, JSON, Markdown, HTML, XML, Excel, copied text and MCP CSV content use a visible `<undecodable TYPE>` string; these text representations do not retain a separate typed marker, so a real text value with the same spelling is ambiguous. SQL export refuses the value. MCP JSON retains an explicit tagged `undecodable` value.
- **Long cells are shown as a preview** (PERF-10). Values over 8 KiB show a typed
  preview and byte count. Oversized text and JSON previews show at most 512
  Unicode characters before their size suffix. View Value and Copy Value use the full value, including
  pending edits and drafts. Browse-table values are refetched by primary key; a
  table without one cannot refetch.
- **Hidden-column projection still needs desktop acceptance** (PERF-9). Merged
  [#384](https://github.com/cozyGarage/BookiE/pull/384) projects hidden non-key
  columns out of the select and refuses full-row copy, row JSON and current-page
  export while those values are unfetched. Installed desktop acceptance follows
  the target and evidence recorded under PKG-1 and PKG-2.
- **A table without a primary key cannot be deleted from the grid** (TEST-14). There
  is no all-column fallback, by design.
- **ClickHouse ambiguous local times:** a `DateTime64` that falls in a repeated or
  missing daylight-saving hour is shown as undecodable and is never turned into a
  literal, because the instant cannot be known.
- **SQLite real numbers:** negative zero and NaN cannot be bound as parameters.
- **SQLite JSON aggregate output** can differ across system SQLite versions (TEST-25).
- **SQL row export does not preserve every server-assigned value.** When column metadata marks a value as generated, SQL export and Copy as INSERT omit it. They also omit auto-increment columns for PostgreSQL and SQL Server, so replay assigns fresh values. They do not emit sequence-state restoration or remap foreign keys to those fresh values. Do not use these row statements as a relational backup. For PostgreSQL backup and restore, use the [dedicated backup tools](user-guide.md#back-up-and-restore-postgresql).
- **CSV import does not map SQL Server IDENTITY columns.** PostgreSQL, MySQL/MariaDB and SQLite can import explicit auto-increment values when mapped. SQL Server identity columns and generated columns remain database-owned ([type and value contract](decisions/0007-type-and-value-preservation.md)).
- **Unzoned PostgreSQL `timestamptz` CSV values** are currently interpreted as UTC. [PostgreSQL](https://www.postgresql.org/docs/current/datatype-datetime.html) normally interprets unzoned timestamp input in the session time zone; the import rule is tracked in [#857](https://github.com/cozyGarage/BookiE/issues/857). Include an explicit zone in the CSV to avoid ambiguity.
- **MongoDB:** browse pages are separate observations, not one point-in-time view (TEST-12); a column with mixed types is read-only. Compatible `_id` pages can use keyset seeking ([#493](https://github.com/cozyGarage/BookiE/pull/493)), and supported sort requests run server-side ([#837](https://github.com/cozyGarage/BookiE/pull/837)). Sorted pages outside the compatible `_id` keyset path and keyless deep pages still use offset pagination. Installed and representative-network acceptance is tracked under PERF-3 / [#555](https://github.com/cozyGarage/BookiE/issues/555).
- **MySQL failed batches:** rollback of a failed batch is verified for InnoDB and a Docker matrix that includes MyISAM, MEMORY, CSV, ARCHIVE, `MRG_MyISAM`, BLACKHOLE, Aria and related side effects; optional or vendor engines and package acceptance are tracked under B4-11.

## Editing and connections

- **PostgreSQL behind a connection pooler:** PgBouncer in session mode works. In transaction mode it works when the pooler supports prepared statements (PgBouncer 1.21 or newer with `max_prepared_statements` above 0); without that, workloads can succeed but backend switching can cause prepared-statement conflicts. Such errors include a pooler configuration hint. Session features of the editor (`SET`, temporary tables, an open transaction across statements) need session pooling by design.
- **SSH jump chains cannot be edited in the form** (UI-1b / [#548](https://github.com/cozyGarage/BookiE/issues/548)). They connect and run, but editing remains disabled until the complete GTK editor path is implemented and accepted.
- **Reusable SSH profiles cannot be edited** (UI-26).
- **Local socket endpoint differences:** PostgreSQL selects a socket directory plus port; MySQL and MariaDB select the full socket-file path. Both local routes reject TLS and SSH and never fall back to TCP. A connection URL names a local socket with `?socket=/path/to/mysqld.sock` (MySQL, MariaDB) or `?host=/socket/directory` (PostgreSQL), with an empty host or `localhost`, and no other option.
- **SQL Server with Kerberos** has a Samba AD and verified-TLS fixture that passed the Kerberos selectors; Windows AD interoperability and package acceptance are tracked under B4-21.
- **SQL Server query cancellation is not supported yet.** A Tiberius 0.13 probe did not receive SQL Server's cancellation acknowledgement after the active operation was interrupted. BookiE keeps server-side cancellation disabled; an interrupted operation remains unknown and its connection or session is retired. A working acknowledged path and read/write outcome rules are tracked under B4-23 / [#850](https://github.com/cozyGarage/BookiE/issues/850).
- **DuckDB read-only flat files** need Linux and a writable directory on the same filesystem as the file (the application pins the file through a private link there). A read-only in-memory DuckDB connection is refused.

## Interface

- Multi-cursor editing is not available (UI-22 / [#552](https://github.com/cozyGarage/BookiE/issues/552)). Split panes and SQL code folding are available. Vim keys are an opt-in preference; typed vim commands in a running editor are not yet covered by an installed scenario. Preview tabs are temporary and are not restored after restart; tabs you keep are restored (UI-17b). Query history now opens in a docked panel (UI-18).
- The PostgreSQL catalog lists materialized views, routines, triggers, sequences, extensions and roles; a typed activity console is deferred and the activity dialog stays a plain result grid (UI-23).
- Text and JSON values over the 8 KiB preview threshold can be edited in the full-value dialog up to 1 MiB. Invalid JSON cannot be staged; SQL NULL, empty text, JSON `null`, and text `null` remain separate values. View Value and Copy Value expose the full value. Values over 1 MiB remain read-only.
- No server messages (NOTICE, PRINT) and no timing breakdown; timing shows elapsed time only (UI-20, PERF-4 / [#550](https://github.com/cozyGarage/BookiE/issues/550)).
- No foreign-key value picker or estimated row counts (UI-19 / [#549](https://github.com/cozyGarage/BookiE/issues/549)). Enum and set pickers and tab-separated row paste are implemented.
- PostgreSQL schemas can be hidden from the sidebar per connection ([#580](https://github.com/cozyGarage/BookiE/issues/580)); this display filter does not reduce catalog query work. Many-schema performance and restricted-role metadata acceptance remain with [#580](https://github.com/cozyGarage/BookiE/issues/580), reopened on 2026-10-22.
- Database snapshots and one-click rollback remain unavailable. ADR 0015 records the design; implementation is post-0.2.0 backlog work tracked by SNAP-2 to SNAP-4 / [#547](https://github.com/cozyGarage/BookiE/issues/547). PostgreSQL logical backup and restore are available through the installed `pg_dump` and `pg_restore` tools; see the [user guide](user-guide.md#back-up-and-restore-postgresql). They are not point-in-time snapshots.
- Accessibility is not fully verified with Orca, keyboard-only navigation or high contrast (DOC-3). The specific missing-name and action reports in [#658](https://github.com/cozyGarage/BookiE/issues/658) were rechecked and resolved in [#920](https://github.com/cozyGarage/BookiE/pull/920); broader acceptance is tracked under DOC-3.

## Platforms and packaging

- The 0.2.0 desktop target is Arch Linux / Omarchy under Hyprland as a native Wayland client. Installed package acceptance, including install, upgrade and rollback, is tracked under PKG-1 / [#574](https://github.com/cozyGarage/BookiE/issues/574); Xvfb results do not count.
- Native Debian and Ubuntu GNOME desktop acceptance is tracked under the later PKG-2 phase, although the packages build and the installed test suite passes in containers.
- Flatpak is not offered. Flathub submission and screenshots are tracked under PKG-4 and PKG-8; the earlier manual install and launch checks are recorded in the [platform guide](platforms.md#flathub).
- Windows and macOS are not supported; the application is built for Linux with GTK 4 and libadwaita.

## Known bugs and unresolved outcomes

- **Unresolved transaction after PostgreSQL session loss** ([#1016](https://github.com/cozyGarage/BookiE/issues/1016)). Reporting the outcome as unknown and refusing further governed writes on that connection is intentional: a disconnected session cannot confirm whether its transaction committed. The editor closes the unusable session without sending ROLLBACK through it. The PostgreSQL release regression in [#998](https://github.com/cozyGarage/BookiE/pull/998) checks that reconnecting never reuses a new backend as the old session. A fresh session may run reads and end its read-only snapshot with ROLLBACK; commits and other governed writes remain blocked until the unresolved outcome is reconciled. The app has no in-app reconciliation action yet ([#947](https://github.com/cozyGarage/BookiE/issues/947)).
- **Catalog kind selection may shift the schema search field** ([#660](https://github.com/cozyGarage/BookiE/issues/660)). Check the issue for current reproduction and fix status.
- **Two installed launches were reported to abort inside BookiE** ([#666](https://github.com/cozyGarage/BookiE/issues/666)); consult the issue for diagnosis and current status.
- **Installed GTK suite has had intermittent Forgejo failures** (TEST-31 / [#556](https://github.com/cozyGarage/BookiE/issues/556)): the startup restore layout abort was fixed in [#821](https://github.com/cozyGarage/BookiE/pull/821). Historical failures also include application shutdown with a bad exit status after scenarios passed. Check TEST-31 and #556 for current run evidence.

## Test and CI limits

- The installed GTK suite does not pass reliably on a native Ubuntu 24.04 runner (TEST-28); it passes in the Debian 13 and Ubuntu 24.04 containers.
- Mutation results are tied to their source SHA; use the latest [TEST-2 / #559](https://github.com/cozyGarage/BookiE/issues/559) report for survivor and timeout status. Expected-value provenance is tracked separately by [TEST-32](oracle-review.md).
