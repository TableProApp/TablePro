# BookiE 0.2 release documentation and source audit

Baseline: `aeac107a4`, branch `linux`, 2026-10-03. This audit uses the shared
checkout and warm `linux/target`; no worktree, cache cleanup, hosted run or
release publication was needed. Source version remains 0.1.5; target is 0.2.0.

## Scope and conclusion

All **83 tracked Markdown files** at the baseline (77 first-party, six vendor)
received a local inventory, fingerprint, inline-link/heading and exact-paragraph
duplicate screen. Current guides, accepted ADRs and high-risk claims were
compared with their owning source, manifests, tests and runners. Historical
ledgers remain evidence at their recorded revisions. This is not exhaustive
semantic proof of every historical sentence or every driver/native type.

The production workspace graph remains acyclic: core and SSH have no workspace
dependencies; policy and drivers point inward; GTK belongs to the app; both
composition roots use shared transport and policy. The architectural decisions
fit together. Current implementation gaps and contradictory conventions needed
correction; a new architecture is not warranted.

The release is **not qualified**. A passing suite covers its assertions, not all
consumers or installed behavior. B3/B4 and frozen-candidate Arch, Debian/GNOME,
upgrade/rollback and soak gates remain open.

## Documentation cleanup

| Change | Reason |
| --- | --- |
| Compact B4 board; original packets in [B4 history](b4-history.md) | Stop merged F6/F8 and other delivered tasks being dispatched again; retain original SHAs/reports |
| Current [connections](../connections.md); September claims in [history](connections-history.md) | Remove obsolete silent host learning, missing SQL Server TLS fixtures and backend fallback claims from the operational guide |
| [Testing](../testing.md) references the executable driver list; adoption narrative in [history](testing-history.md) | Copied commands omitted MongoDB/MCP/policy/SSH; historical counts do not prove current gaps |
| [Validation playbook](../validation-playbook.md) separates commands from [historical results](validation-history.md) | Reuse this checkout/cache; give each runtime result one owner |
| ADR 0004 distinguishes absent items from typed keyring failure | Match storage/transport refusal and recovery behavior |
| ADRs 0006/0008 and [conventions](../code-conventions.md) agree on privacy and uncertainty | Logging level never permits secrets; GUI F8 is merged but headless parity is incomplete |
| Conventions allow concrete shared dialect contracts and wrapper review | Avoid forcing a new trait for every dialect branch or contradicting existing shared parsers/builders |
| Error/state guides link actual source instead of incomplete examples | Avoid teaching silent storage defaults or obsolete error variants/paths |
| Three broken type/value anchors repaired | Restore navigation to actual native case evidence |
| Flathub, Omarchy and production readiness notes state their scope | Build manifests are not publication; old package library requirements are not current source requirements |

Before cleanup, **114 inline references to absent cache reports/logs** and one
vendored Redis `DEVELOPMENT.md` reference were found. There were no missing
first-party source-file targets. This count includes the consolidated archives,
which the earlier 72-file audit predates. Missing historical output remains
unavailable, not a pass. Recover exact-SHA artifacts or rerun only the cases
required for current acceptance. Do not delete a dated record merely because
its local cache has gone. Inventory and fresh logs are retained under
[audit evidence](../evidence/release-audit-2026-10-03/manifest.json).

## ADR implementation check

| ADR | Current source and remaining limit |
| --- | --- |
| 0001 static drivers | Both composition roots register compiled drivers; no runtime plugin system |
| 0002 native Linux GTK | Manifest/toolchain baseline agrees; source build does not qualify either installed desktop |
| 0003 Relm4 ownership | Typed messages and session/live identities exist; preserve documented main-thread registries and stale-reply guards; U3 completion identity still collapses schema/case |
| 0004 keyring | Missing item and typed access failure are distinct; no plaintext credential fallback in saved assembly |
| 0005 cancellation | PostgreSQL/MySQL/SQLite/ClickHouse advertise support; other engines refuse the capability. Shared interruption sequence and server-confirmation tests exist |
| 0006 panic containment | Unwind remains enabled; guard converts errors and GUI signals replacement. Raw payload logging/default hook and headless retirement remain gaps |
| 0007 value preservation | Native fixtures assert bytes/kinds/keys and safe refusal. MySQL zero-row metadata and bounded transaction delivery now have local native regressions; ordinary PostgreSQL custom-enum scalar/array projections and schema-aware keyed update/draft insert writes preserve labels and SQL NULL with native type/sibling oracles. A native PostgreSQL 16 projection also confirms a domain over an enum preserves the literal `NULL` label, Unicode, SQL NULL, and the domain type; this does not establish domain support in other consumers. The literal label `NULL` is preserved on keyed writes and direct scalar/array results after fixing SQLx's quoted text-array decoder. UPDATE RETURNING persists the label and fires one trigger effect. Schema-aware enum comparisons and CSV imports use catalog-qualified parameter casts. Raw PostgreSQL text and SQL NULL parameters now use server-inferred enum types when expression context identifies them, covering query, update and transaction bindings. Default blank enum import is refused as ambiguous; an explicit NULL marker preserves empty labels and SQL NULL separately. Shared JSON, MCP `execute_query`/`export_data`, and core JSON/CSV/SQL/XML/HTML/Markdown file writers have native enum contracts. XLSX writes tested non-empty enum labels as text and safely refuses empty labels without replacing an existing workbook. MCP and core CSV responses use collision-free null markers; native export/import round trips verify enum type/value, including empty text and marker-shaped/formula-shaped text in raw mode. The broader per-consumer and formula-safe CSV configuration matrix remains open |
| 0008 sessions/trust | F4/F9, consent and GUI generation split are integrated. MySQL batch dispatch also refuses DDL/multi-statement entries; this dedicated batch API remains distinct from shared-session transaction-control SQL. Agentd still shares uncertainty and lacks forced fault retirement; C6/G5/I2/I5/F7 acceptance remains |
| 0009 durable compatibility | Stable IDs, version checks, backups/mirrors and distinct writer contracts remain. Installed rollback and shutdown qualification require B7 proof |

## Test quality findings

The recent temporal and BSON contracts use native send bytes, BSON kinds and
unchanged sibling rows/documents. Their acceptance is stronger than display
equality. App-server registers the native fixtures; isolated runners require
each selector to execute once. Harness tests retain zero-test, timeout,
wrong-selector, missing-output and workflow-wiring failures.

Two assertions were strengthened in this audit:

- `abandoning_an_old_write_after_replacement_keeps_the_new_generation_writable`
  starts a real pending fake-driver write, creates a replacement, abandons the
  old future, and verifies old-generation no-dispatch plus successful replacement
  dispatch/audit. It passed normally and failed when uncertainty was deliberately
  redirected to the global journal flag. The mutation was restored; this is a
  focused regression-quality check, not a broad mutation pass.
- PostgreSQL's scalar-enum text fixture asserts complete row cardinality before
  `zip`. New native cases prove ordinary custom-enum scalar and array
  projections preserve exact labels, native type text, and SQL NULL. A quoted
  literal label `NULL` exposed a SQLx text-array parser bug: the decoder
  stripped quotes, then treated the resulting string as SQL NULL. A patched SQLx
  parser regression now distinguishes quoted `NULL`, unquoted SQL NULL, lowercase
  `null`, empty text and ordinary text. Native scalar and array contracts return
  the literal label exactly; `UPDATE ... RETURNING` persists it and fires the
  trigger once. See [the enum evidence](../evidence/postgres-enum-results-2026-10-03/manifest.json).
- The PostgreSQL enum `render_json` case also asserts the server type and exact
  JSON values for literal `NULL`, an empty label, Unicode and SQL NULL. MCP
  `execute_query` and `export_data` now have PostgreSQL 16 contracts for these
  labels. JSON preserves the values. MCP CSV returns a per-result null marker
  absent from exported text; the native regression imports the exact response
  content with that marker and verifies native enum values and types. Core file-writer JSON and CSV
  outputs have native enum contracts. Spreadsheet-safe CSV prefixes formula-like
  enum text with an apostrophe; a native case proves the distinct labels =1+1
  and '=1+1 become the same imported value. This mode is for spreadsheet use,
  not lossless restore. The export dialog says to turn it off for lossless
  re-import. Raw-text CSV remains the tested native round-trip mode. SQL
  file-writer output also replays into
  a PostgreSQL enum destination: empty, literal `NULL`, Unicode, SQL NULL and an
  apostrophe/semicolon label retain their values and native enum type. A native
  XML file-writer case also distinguishes literal `NULL`, empty text and SQL
  NULL while escaping a markup-shaped label. An HTML file-writer case also
  preserves enum/null distinctions and escapes an image/event-handler label as
  text. A Markdown file-writer case now quotes text cells and escapes table and inline markup, distinguishing literal `NULL` from SQL NULL. The XLSX file writer also exports non-empty enum labels as strings and refuses an empty enum label without replacing an existing workbook.
- The MongoDB sparse-document regression exposed an ADR 0007 violation: an
  absent field and explicit BSON null both became `Value::Null`. The driver now
  returns its distinct undecodable marker for an absent field, and its binding
  path refuses that marker. The native test independently checks BSON presence
  before checking the driver result; the original regression failed on the
  conflated value.

Do not close cases from test names or total counts. For each future fix retain
the initial failure, exact selector, valid/invalid neighbors and independent
native postconditions. Do not broaden an error matcher, remove a fixture or
replace exact comparisons just to turn a suite green.

## Source findings and patch status

1. **Privacy:** `policy/src/guard/panic_boundary.rs::report` logs arbitrary
   dependency panic text; the default hook can print it too. Neither routing nor
   error level is redaction. Add sentinel tracing/stderr/error/audit tests.
2. **Headless ownership:** `agentd/src/lib.rs::connection` clones one shared
   `AuditState` and creates a guard without a fault sink. Cache reuse only checks
   ping/material. GUI generation isolation and forced retirement do not carry
   over automatically.
3. **Transaction result claims (patched locally):** PostgreSQL/MySQL batch
   executors now preserve rollback errors as
   `TransactionRollbackFailed`; policy marks the outcome unknown and the UI
   warns that changes may have applied. MySQL batch dispatch accepts only one
   parsed INSERT/UPDATE/DELETE per entry, so DDL and multi-statement entries are
   refused before transaction dispatch. Native MySQL tests cover refusal,
   successful DML, confirmed rollback and rollback failure. PostgreSQL's
   rollback-failure path has source/unit coverage; its native rollback-failure
   acceptance remains open.
4. **MySQL result delivery (patched locally):** query metadata is prepared
   independently of returned rows for shared, parameterized, controlled,
   paged-table and transaction query paths. Transaction results use the shared
   row cap and report truncation. Native regressions cover zero-row metadata on
   shared, parameterized, paged-table and transaction paths, plus the cap.
5. **Known upstream owners still apply:** U2 literal identity handling, U3
   schema/case/dotted completion, U4 permanent-error retries and U5 saved mTLS
   assembly still have source gaps. MongoDB browse rows now share one cursor
   with their full collection metadata scan; native failpoints verify an
   off-page type change observed later in that cursor and absence of a second
   page `find`. Full-scan cost, writes to already-read documents, `run_find`'s
   separate schema/query reads, export scope and installed editing remain open.

## Local validation

Fresh local gates and native probe status are recorded in the retained
manifests. The initial `full security-policy widgets app-server
packaging-contracts` run passed. After the late-generation test, `full
security-policy ssh tls postgres-release` passed. The MySQL patch then passed
the quick and complete `drivers` layers; the latter includes native MySQL and
PostgreSQL integration suites. The expanded MySQL suite has a separate latest
run in the MySQL fix evidence. These use real local containers where named;
widget automation uses Xvfb, not native Wayland. Packaging contracts test
validators, not installation. The ordinary custom-enum scalar/array focused
selection passed all three selected tests previously. The filter follow-up
passed 502 core tests and 74 PostgreSQL integration tests. The later CSV-import
follow-up passed 504 core tests and 75 PostgreSQL integration tests. Its first
native run showed an INSERT plan with untyped `$2` for an enum column; the final
case verifies schema-qualified binding, safe refusal of ambiguous default
blanks without modifying the destination, and exact import using an explicit
NULL marker. Failure-first logs, native checks and source/result fingerprints
are retained in [the enum evidence](../evidence/postgres-enum-results-2026-10-03/manifest.json).
Final formatting, affected-crate Clippy, guards and the restored late-generation
test are retained in `final-checks.json` and the MySQL fix evidence.

No hosted status was needed for these findings. The passed `drivers` layer is
not the complete ADR 0007 engine/type/consumer matrix or optional DuckDB
qualification. Broad mutation/coverage, supply-chain freshness, installed UI,
Wayland, package upgrade/rollback and soak have not been newly certified by
these gates. Reuse previous proof only at matching fingerprints.

## Native MySQL reproductions

The [probe source](../evidence/release-audit-2026-10-03/mysql_probe.rs) uses the
production MySQL driver and includes the production UI error renderer; its
`tr!` macro supplies English strings without instantiating GTK. A disposable
MySQL fixture returns:

```text
projection columns: nonempty=2, shared-empty=0, transaction-empty=0
persisted rows after claimed rollback: [[Int(1)]]
```

The projection is identical except for its true/false predicate. For the second
case, the driver executes INSERT, CREATE TABLE, then an INSERT into a missing
table. It returns `Transaction { statement_index: 2, ... }`, yet row 1 remains.
The production renderer says the transaction rolled back and no rows changed.
[Exact output](../evidence/release-audit-2026-10-03/mysql-probe-native.txt) retains
that contradiction. This proves the driver/renderer paths, not an installed UI
interaction or a guarded route. The policy's transaction audit already treats
errors conservatively as Unknown; that does not correct the user-facing claim.

The probe is diagnostic and exits successfully when it reproduces these gaps;
it is not a passing product regression. Future patches must add expectations
for correct behavior to the owning driver/consumer tiers and observe them fail
first. It was copied temporarily to `crates/app/examples/release_audit_mysql_probe.rs`,
built and removed. To repeat, copy it there and run from `linux/`:

```bash
rtk cargo run --locked -p tablepro-app --example release_audit_mysql_probe
```

Remove the copy before the normal guards. It requires Docker. The first wrapper compile
used the wrong crypto-provider module; the corrected build succeeded. A sandbox
Docker denial was rerun with approved socket access. Both are retained as
execution setup failures, not product failures.

### Resolution checkpoint

The four MySQL tasks below have permanent native regressions. Empty-result
metadata is covered through shared, parameterized, paged-table and transaction
queries; the cap, DDL refusal, successful INSERT/UPDATE/DELETE, confirmed DML
rollback and rollback failure after connection loss are also covered against
disposable MySQL containers. The before-fix logs retain three failing
assertions, and a deliberate rollback-error mutation fails its regression.
Source and validation fingerprints, commands and outcomes are indexed in
[the MySQL fix evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json).
The policy audit and UI renderer unit regressions pass. A focused native case
now shows an InnoDB insert rolling back while its AFTER INSERT trigger's MyISAM
write persists; the user-facing warning matches that behavior. This is local
working-tree evidence, not a hosted check, frozen candidate or installed UI
acceptance. It does not establish semantics for every storage engine or
side-effect pattern. See the [MySQL evidence manifest](../evidence/mysql-atomic-results-2026-10-03/manifest.json).

## Small release tasks

Keep the existing IDs. Each row is one patch or one bounded evidence packet;
larger acceptance groups should be executed as individual named scenarios.

| Risk rank / owner | Task | Closure evidence |
| --- | --- | --- |
| 1 / privacy | Remove sensitive panic payload output, including default-hook leakage | Sentinel absent from captured tracing/stderr/returned errors/audit; containment and terminal state retained |
| 2 / G5 | Retire/invalidate the daemon handle after panic or disconnection even when ping succeeds | Fake-driver no-reuse/no-replay and real loss/panic fixture; stale handles refuse |
| 3 / F8-headless | Scope daemon uncertainty by cached live generation | A blocked, B writable, replacement recovery, late A isolation; journal failure blocks all |
| 4 / B3-P5 MySQL metadata | **Source/regression complete locally.** Preserve zero-row columns through shared, parameterized, paged-table and transaction queries | [Selectors and evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json); candidate matrix acceptance remains |
| 5 / B3-P5 MySQL cap | **Source/regression complete locally.** Bound transaction query materialization and report truncation | [Cap selector and evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json); candidate timeout/rollback postconditions remain |
| 6 / B4 atomic batch | **Source/regression complete locally.** Refuse non-DML MySQL batch statements before dispatch | [DDL refusal and DML controls](../evidence/mysql-atomic-results-2026-10-03/manifest.json); installed acceptance remains |
| 7 / B4 rollback error | **Source/regression complete locally.** Propagate rollback failure to the driver error, unknown audit outcome and honest UI message | [Connection-loss case and consumer regressions](../evidence/mysql-atomic-results-2026-10-03/manifest.json); PostgreSQL native rollback-failure acceptance remains |
| 8 / B3-P1 | Freeze the finite remaining engine/type/consumer/configuration matrix | Every in-scope row has an outcome, exact selector and native proof; accepted refusal IDs retained |
| 9 / B3 PostgreSQL enum | Cover remaining PostgreSQL enum consumers and configurations | Ordinary custom-enum scalar/array results, inferred raw text/NULL query and write parameters, schema-aware writes/filters, same-named enum types shadowed across schemas while search_path points at the shadow schema, CSV import, shared JSON rendering, MCP `execute_query` plus JSON/CSV `export_data`, replayable SQL file output, and XML/HTML/Markdown/XLSX file-writer outcomes are covered, including explicit refusal for an empty XLSX enum label. MCP and core file-writer CSV outputs use collision-free null markers; native tests import the exact emitted content and verify native values/types, while default blank export is refused before writes. A three-level domain-over-enum chain now has native projection, catalog, filter and write proof. Raw uncast domain comparisons return PostgreSQL SQLSTATE 42883; a native query case verifies that refusal and confirms casting the column to its base enum enables inferred text/NULL parameters. Other operator contexts remain open. See [enum evidence](../evidence/postgres-enum-results-2026-10-03/manifest.json), [three-level domain evidence](../evidence/postgres-three-level-domain-results-2026-10-03/manifest.json), and [nested-domain evidence](../evidence/postgres-nested-domain-results-2026-10-03/manifest.json) |
| 10 / U1 then U2 | Finish server-owned consumer evidence; separately fix identity copying | SQL Server native metadata/edits; PostgreSQL ALWAYS/BY DEFAULT and SQL Server copied INSERTs execute safely |
| 11 / U3 | Preserve schema, quoted case and dotted identifiers in completion | Actual candidates from disjoint schemas, delayed replacement replies and failed-fetch retry |
| 12 / U4 | Keep typed reconnect failure classification | Permanent TLS/auth/config stops attempts; transient loss recovers; cancellation stops pending work |
| 13 / U5 | Scope supported saved mTLS paths before implementation | Required-client-cert server, direct/SSH, missing/wrong/rotated files; GUI and daemon parity |
| 14 / U6 | Measure MongoDB census cost; test writes to already-read documents and `run_find`/export boundaries | No lossy mutation, defined read-consistency contract, exact export scope and bounded cancellation/cost; preserve canonical BSON |
| 15 / B3-P6 and R6 | Triage one real survivor/timeout group and repair portable acceptance evidence | Independent assertion or justified equivalence; durable sanitized logs/fingerprints; unavailable output stays unproven |
| 16 / auth fixtures | Replace SCRAM source-string evidence with hostile handshake scenarios | Short/non-ASCII nonce and excessive iterations refuse safely without panic/expensive work |
| 17 / B4 remaining | Execute C6-MySQL, C6-SQLServer, G5 OpenSSH, I2, I5, F7 and I3 as separate packets | Exact assertions and local layers in [the B4 board](../b4-task-board.md#remaining-tasks) |
| 18 / B7 | Frozen SHA: Arch native Wayland, I1 Debian helper, GNOME Wayland, upgrade/rollback, then soak | Exact artifact/checksum, per-scenario results; 30 retry-free GTK attempts across at least six runs |
| 19 / MySQL batch engine semantics | **Narrow trigger contract now has native proof:** an InnoDB insert rolls back while its trigger's MyISAM side effect persists, matching the UI warning | [Native regression and evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json); other storage engines and side-effect patterns remain open |
| 20 / B3 SQLite STRICT ANY | **Parser/keyed-write regressions complete locally.** Existing INTEGER, REAL and TEXT cells retain their runtime kind; clearing existing TEXT stores empty TEXT, empty NULL/new cells store NULL, nonempty NULL/new input stays TEXT instead of guessing a numeric kind, and BLOB values remain read-only with exact bytes. Compound-result and direct table-projection workbooks keep formula-shaped text through LibreOffice Calc ODS/XLSX re-save, with no formula cells | Installed GTK grid editing and other SQLite consumer combinations or spreadsheet apps remain open in B3/B7. [Grid regressions](../evidence/sqlite-strict-any-results-2026-10-03/manifest.json); [Calc formula-text re-import](../evidence/sqlite-xlsx-calc-formula-text-results-2026-10-04/manifest.json) |
| 21 / B3 DuckDB ENUM grid | **Grid input policy and keyed edits now have local app/native proof.** Blank input remains SQL NULL; `''` explicitly enters an empty enum label; doubled single quotes are decoded. Tests preserve native ENUM type and sibling values and refuse an invalid label without changing the row | Installed GTK editing and broader DuckDB type/consumer/configuration parity remain open. [Native keyed-edit regression and evidence](../evidence/duckdb-enum-keyed-results-2026-10-03/manifest.json) |

The audit ranks privacy and headless ownership (rows 1–3) as high-risk gaps;
that risk ranking does not change the approved sprint sequence. Follow
**B3 → B4 → installed qualification**: close the remaining B3 matrix and enum
cases first, then take the privacy/headless B4 tasks and other B4 acceptance.
Risk review and preparation may overlap where they do not reserve the same
files or fixtures. No goal was created and no release decision was made by this
audit.
