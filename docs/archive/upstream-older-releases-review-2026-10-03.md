# Older TablePro app releases: Linux follow-up review

Reviewed 2026-10-03 against Linux `4b7814f5e1f586c3761c1454e66d3394ad2c9609`.
The requested scope is **older TablePro app releases**. macOS operating-system
compatibility is outside this review.

## Scope and evidence

The paginated GitHub releases API returned 672 release records. Filtering exact
`v<major>.<minor>.<patch>` tags leaves **128 app releases**, from `v0.1.0` to
`v0.77.0`, published February 7 through October 2, 2026. Plugin release tags are
excluded. [The retained inventory](upstream-older-releases-2026-10-03-inventory.md)
records every app release, its URL, publication time, release-body digest and
screened fix/security bullet count. Empty fix sections establish no conclusion.

All release bodies were screened for correctness/security themes; the clusters
below received comparison with relevant Linux source and existing ledgers.
This is not a diff audit of every historical commit, nor a new native-runtime
test run. Release notes identify candidate behavior; they do not prove a Linux
bug. Fetch a selected upstream issue/diff and demonstrate a local failure before
implementing a candidate.

Earlier reviews cover [0.62–0.72 adoption](upstream-adoption.md) and
[recent main commits](upstream-main-review-2026-10-03.md). This pass adds the
pre-0.62 screen and explicitly considers 0.73/0.74. Do not duplicate existing
U1–U6, B3 or B4 packets. The [consistency review](architecture-consistency-review-2026-10-03.md)
explains the shared architecture and document authority.

## Applicability and existing safeguards

Paths in this table are relative to `linux/`. “Present” means source inspected;
earlier passing tests remain attributable to their recorded revision.

| Release references | Linux comparison | Disposition |
| --- | --- | --- |
| [0.3.0](https://github.com/TableProApp/TablePro/releases/tag/v0.3.0), [0.5.0](https://github.com/TableProApp/TablePro/releases/tag/v0.5.0), [0.15.0](https://github.com/TableProApp/TablePro/releases/tag/v0.15.0): catalog identifiers and real constraint names | Existing bound catalog lookups and `core/src/sql_ddl/` dialect quoting; U1 keeps bound schema/table values | Keep dotted/quoted-name regressions; no wholesale Swift SQL transplant |
| [0.14.0](https://github.com/TableProApp/TablePro/releases/tag/v0.14.0), [0.31.5](https://github.com/TableProApp/TablePro/releases/tag/v0.31.5), [0.56.0](https://github.com/TableProApp/TablePro/releases/tag/v0.56.0): row targeting | `app/src/ui/browse_tab/row_ops.rs` refuses persisted-row deletion without a PK; composite-key checks and `change_tracker.rs` retain every component | Preserve refusal. Do not add all-column fallback from macOS without a separate safe identity design |
| [0.9.3](https://github.com/TableProApp/TablePro/releases/tag/v0.9.3), [0.17.0](https://github.com/TableProApp/TablePro/releases/tag/v0.17.0), [0.23.2](https://github.com/TableProApp/TablePro/releases/tag/v0.23.2): TLS selection and tunnel identity | `transport/src/lib.rs` retains original service identity; per-engine TLS fixtures exist | B4 C6 owns remaining tunnel combinations. Keep TLS mode semantics and no-fallback checks |
| [0.20.0](https://github.com/TableProApp/TablePro/releases/tag/v0.20.0), [0.31.5](https://github.com/TableProApp/TablePro/releases/tag/v0.31.5), [0.33.0](https://github.com/TableProApp/TablePro/releases/tag/v0.33.0): reconnect, selected database and dirty state | Shared transport rebuilds a route; `ConnectionIdentity` protects catalog callbacks; dedicated editor sessions carry their own UUID | Existing B4 F3/F4/F5/F9 own acceptance; old-session and startup-namespace cases remain useful tests |
| [0.33.0](https://github.com/TableProApp/TablePro/releases/tag/v0.33.0), [0.38.0](https://github.com/TableProApp/TablePro/releases/tag/v0.38.0): locked/missing credentials and migration loss | `storage/src/secrets.rs` distinguishes keyring failures from an absent item; transport propagates errors; stable secret/XDG identifiers retained | Corrected stale storage prose. Preserve recovery and package rollback tests; no Apple keychain migration code |
| [0.24.0](https://github.com/TableProApp/TablePro/releases/tag/v0.24.0), [0.32.0](https://github.com/TableProApp/TablePro/releases/tag/v0.32.0), [0.40.2](https://github.com/TableProApp/TablePro/releases/tag/v0.40.2), [0.43.1](https://github.com/TableProApp/TablePro/releases/tag/v0.43.1): long text, integers, editing | B3 value-contract and review ledgers already cover full edit values, NULL/empty distinctions, exact numeric consumers and explicit refusal | Extend native width/encoding/boundary oracles in B3; display truncation must never become stored-value truncation |
| [0.35.0](https://github.com/TableProApp/TablePro/releases/tag/v0.35.0), [0.56.2](https://github.com/TableProApp/TablePro/releases/tag/v0.56.2): qualified completion and expired authentication | Completion still folds/collapses identity; reconnect converts failures to strings and keeps backing off | Reuse U3 and U4. The older releases strengthen the rationale; no second cache or retry engine |
| [0.59.0](https://github.com/TableProApp/TablePro/releases/tag/v0.59.0): no write replay after connection loss | `connection_monitor.rs` re-establishes handles; guarded unknown writes and dedicated session retirement exist | Preserve B4 disconnection contracts. Server-committed/lost-ack writes need an independent row/audit oracle; reconnect success cannot authorize replay |
| [0.61.0](https://github.com/TableProApp/TablePro/releases/tag/v0.61.0): heterogeneous MongoDB fields | Sampled metadata plus returned-page merging still does not prove collection-wide export | Reuse U6; do not expand a sample and call it a census |
| [0.73.0](https://github.com/TableProApp/TablePro/releases/tag/v0.73.0), [0.74.0](https://github.com/TableProApp/TablePro/releases/tag/v0.74.0): export DDL, identity, binary values and cross-database ownership | Current Linux exports loaded results; full SQL dumps, split/gzip exports and backup/restore have separate backlog scope. Literal identity copying is U2; bytea has B3 contracts | Keep feature prerequisites. Linux does not gain a complete backup/dump implementation by copying upstream export fixes |

## Additional reproduction packets

These are candidates, not confirmed defects or completed fixes. Recheck current
source and reserve the relevant files/fixtures before taking a packet. Return
initial behavior, a minimized failing case if found, exact source SHA and
affected-layer results through the [validation playbook](../validation-playbook.md).

### O1: connection and namespace ownership through transitions

Origins: 0.43.2 abandoned connects, 0.73/0.74 stale database ownership.
Owner: existing **B4 F4/F9**, coordinated with F3/F5 and U3.

Inspect `app/src/ui/app/connection.rs`, `services/connection_service.rs`,
`database_service.rs`, `catalog.rs`, and editor session callbacks. A saved UUID,
physical connection identity, editor-session UUID, and selected database/schema
are different identities. Do not replace them with one global generation.

Reproduce slow connect A, cancel/switch to B, late success/error from A; then
reconnect the same saved UUID while a catalog/completion request is pending.
Verify stale resources close, B keeps its state, dirty edits survive or prompt,
and no old callback or selected namespace routes a write to another database.
Installed GTK evidence remains separate from a fake callback test.

### O2: SQL Server large text and binary values

Origin: [0.54.0](https://github.com/TableProApp/TablePro/releases/tag/v0.54.0)
large-text session configuration; owner **B3**, shared with session contracts.

The checked-in MSSQL source has no explicit `SET TEXTSIZE`; that alone is not a
defect because negotiated/default session behavior may suffice. Test ordinary
and dedicated connections with `nvarchar(max)`/`varchar(max)`/`varbinary(max)`
at 64 KiB neighbors and megabyte sizes, including Unicode and empty/NULL values.
Compare exact native `DATALENGTH`, server hash and stored kind against driver,
grid, CSV/JSON/XLSX and re-import results. Add configuration only if a native
failure proves it necessary, and ensure it cannot change audit/transaction state.

The Docker contract now covers the size/NULL/empty, ordinary/dedicated-session,
grid display, CSV and JSON paths. CSV re-import accepts 1 MiB binary values using
a bounded 2 MiB plus prefix field ceiling. XLSX is verified at its per-cell
length boundary and explicitly rejects larger values; it does not promise to
round-trip SQL Server MAX-sized cells. No `TEXTSIZE` change was needed. See
`value_contract_mssql_max_values_survive_connection_session_and_consumers` and
the B3 board for this contract's status.

### O3: result limits and multiple result sets

Origins: 0.17.0, [0.55.0](https://github.com/TableProApp/TablePro/releases/tag/v0.55.0),
0.73/0.74; owner **B3/B4 editor result contract**.

`mssql/src/lib.rs::collect_result` caps the first result set and drains the
entire stream, surfacing later errors while discarding later row sets. Draining
is necessary for server/protocol cleanup; it does not provide multi-result UX.
The editor splits scripts, which does not solve one stored procedure returning
several sets. Current `QueryResult` carries one set.

Docker regressions cover later result sets being discarded while the first
set's columns remain authoritative (including an empty first set), late errors
after the first set, row- and byte-budget truncation, draining, and later
connection usability. Follow-up work remains for independent capped SELECTs in
the editor, stored procedures returning several sets, and connection loss
during drain. Any multi-set API needs core, driver, guard, MCP and GUI consumer
design together; do not change one driver return type or silently apply an
aggregate cap across unrelated statements.

## Changes deliberately excluded

Apple runtime symbols, AppKit/SwiftUI lifecycle, entitlements, iCloud,
Sparkle signing and dynamic-plugin installation do not map to Linux defects.
Upstream native libmariadb/libpq/libssh2/OpenSSL bundle patches do not prove the
same vulnerable dependency exists in the Rust lockfile or system OpenSSH.
Use the existing supply-chain checks for the actual dependency graph. New
engines, built-in AI and paid gates do not enter this correctness pass.

## Completion boundary

This pass expands review coverage and future-agent instructions. U1 is already
implemented with [native before/after evidence](upstream-u1-sql-server-2026-10-03.md).
U2–U6, O1–O3 and wider B3/B4 acceptance remain open. No older release note is
treated as a Linux reproduction, and no milestone or package is promoted.
