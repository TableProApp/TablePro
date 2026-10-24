# Known limitations on the `linux` branch

This page records current branch behavior, including changes made after 0.2.0 was published. It is not a qualification statement for the [0.2.0 release assets](platforms.md#published-020-release). Entries link to their owning issue, decision or evidence when one exists. Issues own current work and acceptance status; this page records user-visible behavior.

## Data and values

- **SQL file layout is bounded per line** ([#1299](https://github.com/cozyGarage/BookiE/issues/1299)). Opening or dropping a SQL file refuses physical lines over 256 KiB of UTF-8 text, alongside the 8 MiB total file limit. Files are not truncated or rewritten. Dropped files are also checked against the complete post-insertion line and 8 MiB editor size before mutation. This boundary prevents the measured single-line file-loading allocation; it does not constrain text already in an editor, pasted text or restored drafts. Those paths and native desktop qualification remain open.

- **Full-table export is unavailable** ([ADR 0014](decisions/0014-full-table-export-snapshot.md)). The current drivers do not have
  a verified snapshot export path, so the application refuses full-table export
  before opening the destination dialog or publishing a file. Export the current
  page or a loaded query result instead. A per-engine consistent export path is
  an unselected future candidate; database snapshots for backup and restore are
  a separate feature with an accepted design and no release target ([ADR 0015](decisions/0015-database-snapshots.md)).
- **Large results still have materialization limits** (PERF-2, PERF-8 / [#554](https://github.com/cozyGarage/BookiE/issues/554)). Materialized
  results stop at 1 million rows, 10 million cells or 64 MiB estimated size.
  Single-statement PostgreSQL `SELECT`s in the SQL editor stream cursor pages
  through Core and PolicyGuard, retaining them while estimated row storage stays
  within 64 MiB and always keeping the newest page, even if it alone exceeds the
  estimate. A native 100,000-row PostgreSQL query returned 20 pages and navigated
  back to rows 1–5,000 after completion. A wide result exceeded the budget and
  evicted older pages, so results larger than the cache budget can still lose
  access to earlier rows. The received-row summary identifies the retained
  range; row ranges are positions in the result, not database row identifiers.
  Incoming decoding, concurrent snapshots, pins, widgets and allocator retention
  remain outside this cache estimate, which is not a process-memory ceiling.
  An October 16 synthetic stress profile at source `9c23bc80` allocated about
  1.28 GiB across four pinned results and one active stream, reaching 1,325 MiB
  RSS ([record](evidence/stream-retention-synthetic-2026-10-16/README.md)).
  Paging and ownership code changed after that run, so it is historical evidence,
  not a current memory bound. The October 24 narrow-query profile kept all
  100,000 rows navigable and showed a 25.3 MiB peak RSS increase over 31 seconds;
  the [capture](evidence/built-head-2026-10-24/README.md) records its limits.
  This single-query result does not measure the pinned-stream stress case, normal
  workloads or the complete process ceiling. Other engines and unsupported
  statement shapes remain materialized. Broader resource, lifecycle and
  cross-engine acceptance remain under [#1032](https://github.com/cozyGarage/BookiE/issues/1032)
  and [#554](https://github.com/cozyGarage/BookiE/issues/554) (ADR 0011).
- **SQL result filters apply only to loaded rows.** Filter and sort actions are local, show the visible and loaded counts, and do not re-run SQL. Clearing a filter restores loaded rows. Settings carry across reruns of the same statement and pin/unpin while the result remains current or pinned. Selection follows source-row identity when the same materialized result is rerendered; a fresh query resets selection. Settings do not survive an app restart.
- **File exports use text markers for undecodable cells** ([#883](https://github.com/cozyGarage/BookiE/issues/883)). CSV, JSON, Markdown, HTML, XML, Excel, copied text and MCP CSV content use a visible `<undecodable TYPE>` string; these text representations do not retain a separate typed marker, so a real text value with the same spelling is ambiguous. SQL export refuses the value. MCP JSON retains an explicit tagged `undecodable` value.
- **Long cells are shown as a preview** (PERF-10). Values over 8 KiB show a typed
  preview and byte count. Oversized text and JSON previews show at most 512
  Unicode characters before their size suffix. View Value and Copy Value use the full value, including
  pending edits and drafts. Browse-table values are refetched by primary key; a
  table without one cannot refetch.
- **Hidden-column projection still needs desktop acceptance** (PERF-9). Merged
  [#384](https://github.com/cozyGarage/BookiE/pull/384) projects hidden non-key
  columns out of the select and refuses full-row copy, row JSON and current-page
  export while those values are unfetched. The owning [#596 issue](https://github.com/cozyGarage/BookiE/issues/596)
  remains open for its driver and installed-GTK acceptance; general package
  acceptance does not establish this behavior.
- **A table without a primary key cannot be deleted from the grid** (TEST-14). There
  is no all-column fallback, by design.
- **ClickHouse ambiguous local times:** a `DateTime64` that falls in a repeated or
  missing daylight-saving hour is shown as undecodable and is never turned into a
  literal, because the instant cannot be known.
- **SQLite real numbers:** negative zero and NaN cannot be bound as parameters.
- **SQLite JSON aggregates can return malformed text on older system libraries** (TEST-25 /
  [#1545](https://github.com/cozyGarage/BookiE/issues/1545)). With an empty key,
  json_group_object(key, value ORDER BY ...) produces malformed output on the
  reported SQLite 3.45.1 and 3.46.1 builds; SQLite 3.53.4 returns the expected
  text. The driver links the system SQLite library. The [current fixture](../apps/linux/app/tests/support/sqlite_any_contract/aggregate_csv.rs)
  preserves the older library output through CSV, but does not make that output valid JSON. It passes on the current local system library, SQLite 3.54.0 ([run](evidence/current-audit-focused-selectors-2026-10-24/README.md#current-sqlite-json-aggregate-rerun-october-24)); the reported 3.45.1 and 3.46.1 outputs were not reproduced on this host.
  Whether to skip this case below the fixing SQLite version or bundle SQLite
  remains undecided.
- **SQL row export does not preserve every server-assigned value.** When column metadata marks a value as generated, SQL export and Copy as INSERT omit it. They also omit auto-increment columns for PostgreSQL and SQL Server, so replay assigns fresh values. They do not emit sequence-state restoration or remap foreign keys to those fresh values. Do not use these row statements as a relational backup. For PostgreSQL backup and restore, use the [dedicated backup tools](user-guide.md#back-up-and-restore-postgresql).
- **SQL Server server-owned columns are omitted from row writes.** CSV import drops mapped IDENTITY, computed and rowversion fields; generated Copy as SQL and SQL export statements omit those values so the destination creates them. The Docker consumer regression checks native rows and metadata, but its grid editability assertion calls the helper directly; installed GTK interaction is not covered ([test](../apps/linux/app/tests/support/mssql_server_owned_columns.rs), [type and value contract](decisions/0007-type-and-value-preservation.md)). PostgreSQL, MySQL/MariaDB and SQLite can import explicit auto-increment values when mapped.
- **Unzoned PostgreSQL `timestamptz` CSV values** are currently interpreted as UTC. [PostgreSQL](https://www.postgresql.org/docs/current/datatype-datetime.html) normally interprets unzoned timestamp input in the session time zone; the import rule is tracked in [#857](https://github.com/cozyGarage/BookiE/issues/857). Include an explicit zone in the CSV to avoid ambiguity.
- **MongoDB:** browse pages are separate observations, not one point-in-time view (TEST-12). Column types are inferred from a bounded `_id`-ordered sample of at most 128 documents and merged with the displayed page; fields or types outside both reads may remain undiscovered. A column with mixed types is read-only. Unsorted forward pages with a compatible `_id` can use keyset seeking ([#493](https://github.com/cozyGarage/BookiE/pull/493)), and supported sort requests run server-side ([#837](https://github.com/cozyGarage/BookiE/pull/837)). Reverse and last-page navigation, explicitly sorted pages, and keyless deep pages still use offset pagination. Installed and representative-network acceptance is tracked under PERF-3 / [#555](https://github.com/cozyGarage/BookiE/issues/555).
- **MySQL failed batches do not undo every side effect** (B4-11). A failed batch rolls back InnoDB changes, but writes to nontransactional tables and some trigger or session effects can persist. Current regressions are in the [shared test matrix](../crates/drivers/mysql/tests/shared/mysql_atomic.rs) and its [focused cases](../crates/drivers/mysql/tests/shared/mysql_atomic_parts/). The [23-test Docker matrix](evidence/b4-mysql-atomic-linux-ecdc8568-2026-10-13/manifest.json) is historical evidence from MySQL 8.1 and MariaDB 11, including MyISAM, MEMORY, CSV, ARCHIVE, BLACKHOLE, Aria, MERGE and FEDERATED cases; it ran at `ecdc8568`. The current local [integration-tier run](evidence/current-audit-focused-selectors-2026-10-24/README.md#local-integration-tier) passed 619 tests on the same MySQL and Core source. Its per-test logs are not retained, so the historical matrix still provides the engine-specific detail. Optional/vendor engines and package acceptance remain open.

## Editing and connections

- **Redis supports a single host/port endpoint.** Sentinel and Cluster topologies are unsupported and have no release target.
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
- Accessibility is not fully verified with Orca, keyboard-only navigation or high contrast (DOC-3). The sidebar and filter-name labels from [#658](https://github.com/cozyGarage/BookiE/issues/658) were fixed in [#751](https://github.com/cozyGarage/BookiE/pull/751); the Environment and Method controls were fixed in [#920](https://github.com/cozyGarage/BookiE/pull/920). The remaining reported controls were rechecked on current `linux` before #658 was closed. Broader acceptance remains under DOC-3.

## Platforms and packaging

- The 0.2.0 desktop target is Arch Linux / Omarchy under Hyprland as a native Wayland client. Installed package acceptance, including install, upgrade and rollback, is tracked under PKG-1 / [#574](https://github.com/cozyGarage/BookiE/issues/574); Xvfb results do not count.
- Native builds and packages require GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22 or newer ([ADR 0021](decisions/0021-toolkit-floor.md)). Ubuntu 26.04 LTS, Ubuntu 24.04 and Debian 13 ship older libraries and are unsupported for these native paths.
- Native Debian GNOME desktop acceptance is tracked under the later PKG-2 phase, although the package builds and the installed test suite passes in a Debian testing container.
- The 0.2.0 release includes a GNOME 50 Flatpak bundle but has no Flathub listing. The current branch targets GNOME 51; a bundle for that runtime is not published. The 0.2.0 bundle does not establish current-source Flatpak acceptance. Flathub publication and its file-access decision remain under PKG-4 and PKG-8; the earlier manual install and launch checks are recorded in the [platform guide](platforms.md#flathub).
- Windows and macOS are not supported; the application is built for Linux with GTK 4 and libadwaita.

## Known bugs and unresolved outcomes

- **PostgreSQL transaction outcome can remain unknown after session loss.** A disconnected session cannot confirm whether its transaction committed, so BookiE records an unknown outcome and blocks governed writes for that connection. The editor closes the unusable session without sending ROLLBACK through it; that teardown fix was merged in [#1086](https://github.com/cozyGarage/BookiE/pull/1086). A follow-up initially found that the new session could not end its read-only snapshot because ROLLBACK was blocked. [#1106](https://github.com/cozyGarage/BookiE/pull/1106) fixed that path, and the tunnel-loss release scenario passed on Forgejo run 679; [#1016](https://github.com/cozyGarage/BookiE/issues/1016) records the verification and is closed. The PostgreSQL release regression in [#998](https://github.com/cozyGarage/BookiE/pull/998) also checks that reconnecting never reuses a new backend as the old session. A fresh session may run reads and end its read-only snapshot with ROLLBACK. Commits and other governed writes remain blocked until the unresolved outcome is reconciled; the app has no in-app reconciliation action yet ([#947](https://github.com/cozyGarage/BookiE/issues/947)).
- **Two installed launches were reported to abort inside BookiE** ([#666](https://github.com/cozyGarage/BookiE/issues/666)); consult the issue for diagnosis and current status.
- **Installed GTK suite has had intermittent Forgejo failures** (TEST-31 / [#556](https://github.com/cozyGarage/BookiE/issues/556)): the startup restore layout abort was fixed in [#821](https://github.com/cozyGarage/BookiE/pull/821). Historical failures also include application shutdown with a bad exit status after scenarios passed. Check TEST-31 and #556 for current run evidence.

## Test and CI limits

- Mutation results are tied to their source SHA; use the latest [TEST-2 / #559](https://github.com/cozyGarage/BookiE/issues/559) report for survivor and timeout status. Expected-value provenance is tracked separately by [TEST-32](oracle-review.md).
