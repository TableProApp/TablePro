# Database-client lessons and BookiE source review

Archived 2026-10-10 from the repository root into `linux/docs/archive/`.
Reviewed 2026-10-06; companion to
[external-audit-2026-10-06.md](external-audit-2026-10-06.md).
This is a bounded review of Linux BookiE and selected primary-source examples,
not an exhaustive audit of any client. Findings nominate work for the existing
[B3](../type-contract-strategy.md) and
[B4](../b4-task-board.md) owners; they did not change sprint order or
claim release acceptance. The implementation follow-up below records changes
made after the review; it does not claim hosted or release acceptance.

## Inspected sources

BookiE advanced from `2d114d424` to
`fc755878333ed4973a773c5a0dca39abe8b3a456` during inspection. The latter
contains the audit previously written in this conversation and the SQLite
underflow follow-up. Read the Linux core manifest/modules, numeric helpers,
grid parsing, CSV cell parsing, native SQLite grid tests, keyed SQL builders,
change-tracker materialization, save dispatch, SQLite transaction/foreign-key
paths, query limits, text-file handling and two SQLite evidence packets.

| Client | Snapshot or primary report | Scope |
| --- | --- | --- |
| dbx | `1ed598308a4c6264c7c6460ae812be8ddde69268` | Core manifest/public modules and the prior architecture/test/CI/fix review |
| DBeaver | [Issue 29309](https://github.com/dbeaver/dbeaver/issues/29309), [PR 35141](https://github.com/dbeaver/dbeaver/pull/35141/files) | Composite metadata bug and actual shared-cache fix; earlier driver reuse review remains separate |
| pgAdmin | `ecb6446c313b69ec1310b5816178e79040f98a92` | [Regression guide](https://github.com/pgadmin-org/pgadmin4/blob/ecb6446c313b69ec1310b5816178e79040f98a92/web/regression/README.md), test/workflow inventory, file-reader implementation and reports below |
| Beekeeper Studio | `c8693a56045e34543ded668aaa78614495a7d01a` | Test/workflow inventory, [PostgreSQL fixture](https://github.com/beekeeper-studio/beekeeper-studio/blob/c8693a56045e34543ded668aaa78614495a7d01a/apps/studio/tests/integration/lib/db/clients/postgres/container.ts), BIGINT export report |
| DB Browser for SQLite | `9dda0687c5213556f4cbc26f83f26e80be0a9606` | Root/test/workflow inventory and unsaved-cell report; no complete C++ architecture review |

External issue bodies are reports, not automatically reproduced defects or
verified fixes. Cross-platform reports are used for database/interaction
invariants applicable to Linux, not for adopting another platform's UI.

## What their bugs teach us

| Evidence | Failure class | BookiE application and decisive regression |
| --- | --- | --- |
| DBeaver 29309 / 35141 | SQLite composite foreign-key columns returned in the wrong order; an earlier attempted fix also broke PK naming | Normalize ordinal metadata at the owning boundary, retaining constraint identity. Test reversed declaration/order, unequal column names and both FK navigation directions. BookiE SQLite already requests `ORDER BY id, seq`; preserve that behavior rather than add redundant sorting everywhere. |
| [pgAdmin 10462](https://github.com/pgadmin-org/pgadmin4/issues/10462) | Encoding fallback restarts a file after earlier chunks were delivered, duplicating its prefix | No transparent restart after delivery. Choose encoding before delivery or explicitly reset the destination; fail without partial success. BookiE `read_text_file` validates complete bounded UTF-8 before returning and has no such fallback. Future streaming readers need a late-invalid-byte test. |
| [pgAdmin 10463](https://github.com/pgadmin-org/pgadmin4/issues/10463) | Reported service-file database settings override a utility's selected database, risking writes to another DB | Resolve effective service identity once and carry it into every consumer. Test conflicting service/environment/selected DB configuration and inspect the server's actual database before mutation. This report was not independently reproduced here. Apply ADR 0008 to any future native utility/JDBC bridge. |
| [Beekeeper 2491](https://github.com/beekeeper-studio/beekeeper-studio/issues/2491) | Reported BIGINT format differs between XLSX download and clipboard; reproduction details are incomplete | A spreadsheet numeric cell may lose wide integers. Exact text can be correct; type appearance alone is not an oracle. Compare native source, workbook cell type and reimported value for BIGINT boundaries across file and clipboard consumers. Do not adopt the report's requested numeric formatting without precision proof. |
| [DB Browser 2488](https://github.com/sqlitebrowser/sqlitebrowser/issues/2488) | Reported draft text disappears when focus moves to another cell | Draft state must belong to a stable row key, not a recycled widget or visible position. GTK regression: edit long text, sort/filter/page/change focus, then cancel or save; assert draft ownership and native persisted result. Closure of the issue does not establish a fix implementation inspected here. |
| dbx PostgreSQL identity/sequence export fix, linked in the parent audit | Replaying rows succeeds but future generated IDs fail or differ | Round-trip acceptance includes the next ordinary insert, real sequence ownership/name, descending/cycling/unused sequences and generated-column semantics; successful import counts are insufficient. |

The common discovery method is to vary one boundary while holding the value
constant: selected versus effective DB; declared versus runtime type; visual
row versus key; emitted versus committed bytes; old versus current generation;
loaded data versus the next server-generated value. Keep a small corpus for
each invariant, not one giant scenario per issue number.

## Test and maintenance practices worth adopting

pgAdmin documents tests beside their owning modules, selectors for a module or
package, separate feature/browser tests and reverse-engineered SQL tests. Its
workflow inventory separates Python/JavaScript/feature/package checks. BookiE
should retain crate ownership and its existing layer registry, with separate
native GTK and installed-package proof. Framework documentation and workflow
presence do not establish passing CI; the guide also contains old setup text.

Beekeeper's reviewed PostgreSQL fixture uses Testcontainers, mapped ports,
temporary socket directories, readiness waiting and configurable read-only and
socket paths. Reuse the isolation principle in existing Rust fixtures. Pin
engine versions/digests and assert fixture readiness. Do not copy its `latest`
version shortcut or infer version capabilities merely from whether a tag is
`latest`; select capabilities by tested version and actual server behavior.

DBeaver's inspected PR repairs composite-cache ordering centrally rather than
patching each navigation consumer. Its issue also shows why narrowing scope
matters: fixing ordering while preserving names avoids a second regression.
For BookiE, keep a reproducer, failing baseline, minimal shared fix, sibling
invariants, exact selectors and native oracles in the same work packet. Keep
test/fix in the same focused commit; log-only evidence refreshes should explain
which source run they record. Do not equate issue closure, test count or source
string assertions with behavior proof.

## BookiE findings and opportunities

### R1 — High: relational grid saves do not detect an intervening value edit

[Change-tracker materialization](../../crates/app/src/services/change_tracker.rs)
retains `(column, previous_value, new_value)` but discards `previous_value` for
ordinary SQL engines. [The shared builder](../../crates/core/src/sql_dialect/updates.rs)
generates `SET new_value WHERE primary_key`. MongoDB uses original-value
predicates. [The save handler](../../crates/app/src/ui/app/row_ops.rs) examines
affected counts after commit; one affected row cannot distinguish a stale
overwrite from a legitimate update. Its helper also accepts every positive
count, despite surrounding text describing an exactly-one invariant.

Confirmed source gap; a native in-memory SQLite probe of the same SQL shape
returned one affected row and replaced `other writer` with `stale grid edit`.
This probe demonstrates SQL semantics, not execution through GTK/PolicyGuard.
Existing core tests explicitly assert the PK-only SQL shape. Current passing
tests therefore do not establish lost-update protection for SQL engines.

One shared improvement can protect edits and deletes across SQL engines:
introduce an explicit mutation plan carrying target identity, original key,
old values/version, new values and expected match semantics. Enforce conflict
checks inside the transaction before commit, preserve pending edits on failure,
and route through PolicyGuard. Decide whether protection covers edited fields
or the full observed row; neither prevents ABA without a server version token.
Do not blindly reuse MongoDB equality: SQL NULL needs dialect-aware null-safe
comparison, and MySQL changed-row versus matched-row reporting needs explicit
handling. Engines without reliable counts need an honest unsupported/refusal
path or a separately proven locking/version strategy.

Implemented for PostgreSQL, MySQL, SQL Server and SQLite: edited values now
join the primary-key predicate using each dialect's NULL-safe equality. Checked
affected counts are validated before commit; a conflict rolls back the full
batch and leaves the change tracker pending for retry or review. The checked
transaction API passes through PolicyGuard. MongoDB retains its existing
compare-and-set path. Other engines are not routed through the new SQL builder.

Regression coverage includes dialect SQL/parameter assertions and a native
SQLite transaction where an earlier insert is rolled back after a stale edit;
the other writer's value remains stored. Remaining coverage: live two-session
tests for PostgreSQL/MySQL/SQL Server, composite-key runtime cases, driver
count anomalies, pending-draft UI interaction, and non-transactional MySQL
tables. These are separate from the local SQLite proof and hosted gates.

### R2 — Medium: evidence lookup can select zero tests or confuse historic source with current source

For [numeric-affinity evidence](../evidence/sqlite-numeric-affinity-grid-results-2026-10-06/manifest.json),
all six current source hashes and seven archived log hashes matched. For
[constraint-refusal evidence](../evidence/sqlite-affinity-check-constraint-results-2026-10-06/manifest.json),
all four log hashes matched; its one source hash differs from the current test
file. A historical hash mismatch is not a failing product test. The top-level
numeric-affinity `test` field also omits the `sqlite_numeric_affinity::` module;
the command inside `validation.focused_test` has the correct selector.

Implemented `linux/scripts/validate-evidence.py`, its unit tests, strict checks
for the two current SQLite evidence packets, and a harness-tier CI invocation.
It checks selector/command agreement, logged execution and pass counts, and
source/log digest shape and archived log digests. Full-history source drift or
missing legacy logs are review warnings; strict current packets fail closed.
The validator leaves historical hashes intact. Run without `--strict` to
inventory legacy warning debt.

### R3 — Medium: row caps do not bound result memory

[QueryResult](../../crates/core/src/query.rs) materializes `Vec<Vec<Value>>` with
`MAX_QUERY_ROWS = 1_000_000`. Reviewed driver paths use row caps; there is no
shared aggregate decoded-byte budget in this contract. A few large text/BLOB
cells can exhaust memory far below a row limit. MCP's request-body cap protects
incoming requests, not database result allocation. GTK virtualization likewise
does not bound the retained backing result.

Implemented a shared decoded-result row/cell/byte budget in `tablepro-core`
and applied it to SQL, document, key-value and Redis result collectors.
Exceeding the budget sets the existing `truncated` flag. The core unit test
covers row, cell and byte boundaries. This retained-value budget does not
include all driver protocol buffers, native client allocations or MongoDB's
intermediate BSON documents; peak RSS, connection reuse after truncation and
GUI/headless delivery remain to measure.

### R4 — Shared parsing is useful; consolidate decisions without erasing engine semantics

The SQLite changes sensibly share `parse_float_input`, `is_numeric_input` and
`sqlite_affinity_decimal` between import and grid paths, then prove native
`typeof()`, exact stored values, siblings and constraint refusal. GUI and CSV
still own separate fallback dispatch/type classification. A future boundary
classifier can return typed value, exact text fallback or refusal plus the
target contract, reducing divergent fixes across both consumers.

Keep this incremental: existing float-column parsing succeeds before the
fallback, and typed floating-point conversion has different semantics from
decimal precision preservation. Do not advertise the fallback helper as an
exactness check for every successful numeric parse. Preserve intentional
NULL/empty and SQLite STRICT/ANY distinctions; prove both consumers and native
storage before replacing their decision paths.

## BookiE core versus dbx-core

The names describe different architectural levels.

| Responsibility | BookiE | dbx at the inspected SHA |
| --- | --- | --- |
| Value/result/options/connection/session contracts | `tablepro-core` | Primarily `dbx-types`, surfaced through reexports |
| SQL syntax/dialects/DML and formats | `tablepro-core` modules | `dbx-sql` family and `dbx-formats` |
| Engine implementations | Separate driver crates depend on core | `dbx-drivers` family, depended on by core |
| Connection orchestration, secrets/persistence, policy and task ownership | `transport`, `storage`, `policy`, `mcp`, consumers and app services | Much of this is assembled/reexported by `dbx-core`, with platform/plugin/AI crates |
| Consumer roots | GTK `app`, headless `agentd`/MCP | Desktop/web/CLI/MCP use the shared orchestration layer |

BookiE core's manifest has no workspace-crate dependencies and no GTK;
it is a foundation contract library with shared conversion/SQL utilities.
[dbx-core's manifest](https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/crates/dbx-core/Cargo.toml)
depends on drivers, SQL, formats, types, platform, plugin runtime and AI provider.
[Its public modules](https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/crates/dbx-core/src/lib.rs)
assemble query/session/cancellation, import/export/transfer, schema, persistence,
safety and host services. Some public surface is compatibility reexporting;
it does not mean all implementations live in that crate.

Do not turn BookiE core into this orchestration crate: core-to-driver
dependencies would reverse today's driver-to-core boundary. Build a stronger
Rust backend by enforcing existing boundaries and sharing concrete services
where GUI and headless duplication is demonstrated. If such a service truly
needs a new crate, put it above core/drivers and below consumer roots, with
an explicit dependency allowlist and both consumers tested. Rust ownership
helps memory safety; it does not itself enforce database identity, stale-write
protection, precision, cancellation or resource budgets.

## Verification in the original review

- `cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib`: **530 passed**, zero ignored/failed.
- App all-features library selector `ui::browse_tab::value_parse::tests::sqlite_numeric_affinity`: **2 passed**, 511 filtered, zero failed/ignored; native in-memory SQLite assertions, not an installed GTK interaction run.
- Two evidence packets: six current matching source digests, one historical differing source digest, eleven matching log digests.
- Pinned pgAdmin reader extracted directly from its source and executed with the reported late Latin-1 byte: input **5,242,884 bytes**, output **9,437,188 characters**, duplicated prefix **4,194,304 characters**. No pgAdmin server/browser run.
- SQLite SQL-semantics probe: stale overwrite affected **1** row. The follow-up adds the Rust rollback regression below.

Commands ran on the changing checkout described above, not an immutable release
candidate. The original review did not run full workspace, server-engine
matrix, GTK/Wayland, packaging, installed runtime or hosted CI. Reconcile each
remaining packet with the current owning board before implementation.

## Implementation follow-up — 2026-10-06

- Local `tablepro-core --lib`: 532 tests passed, including the new result-budget and dialect-builder regressions.
- Local SQLite stale-grid integration: 1 passed; it proves transaction rollback and preservation of the concurrent writer's value.
- Evidence-validator unit tests: 4 passed; strict checks for the two current SQLite packets passed. Historical inventory remains warning-only.
- Linux `ci-local.sh quick`: passed after rerunning unsandboxed for local-socket cancellation tests. It includes the harness, non-GTK Clippy/unit suites and sandbox integration tier; 69 Python tests and 532 core tests passed.
- The stale SQLite integration and change-tracker materialization selectors passed after the transaction helper refactor; actionlint v1.7.12 workflow-lint passed.
- Existing 0.2.0 B3 cases were retained. This follow-up adds independent optimistic-write and result-budget checks; it does not close the B3 sprint or claim cross-engine runtime, installed GTK interaction, packaging or peak-RSS acceptance.
