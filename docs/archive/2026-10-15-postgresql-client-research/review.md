# PostgreSQL client research for BookiE

Reviewed 2026-10-15. Companion [case catalogue](cases.csv) has 46 actionable scenarios, their sources, independent oracles, owning tiers and current evidence status. The JSON version is suitable for selecting a small packet; it is not an executable test suite.

## Scope and confidence

| Repository | Source pin | Focus |
|---|---|---|
| BookiE | `f08746024561e90ade4f7d3e34de3aefb34aa7a2` | Existing PostgreSQL decoder/binder/catalog, cursor lifecycle, completion, current tests and issues |
| dbx | `12139b55df9b4bf0ae89d4fab459bf1871e8a783` | PostgreSQL extension decoding, spatial metadata, export replay and operation budgets |
| DBeaver | `e97f23bcbd68db782b5300591dc4b61366f30c92` | PostgreSQL type/value handlers, metadata identity, SQL formatting, permissions, backup selection and fix history |
| pgAdmin | `607c9eccbffdd1c17f437cb236f7c63d176df4c5` | Query execution/edit safety, cursor control, identity/sequence DDL and regression fixtures |
| pgcli | `baf0f01db64e5ed20337eb9c4dee050dabd5705c` | Completion namespaces, refresh behavior, transaction state and text fallbacks |

Screened 60 recently updated issue records per dbx, DBeaver and pgAdmin query; read selected bodies and relevant source/fix diffs. Reviewed recent clone histories (120 commits for DBeaver and pgcli, 100 for pgAdmin). Search results include unrelated matches and are not all confirmed PostgreSQL defects. The earlier dbx clone contains 350 recent commits. This is not a full audit of any repository or a claim to collect every GitHub edge case.

Local BookiE is `d9066246`; remote linux is `f0874602`. The earlier compare showed the latter's changes do not touch the PostgreSQL query or completion helpers reviewed here. No product files were edited. No PostgreSQL server, Docker fixture, GUI, external client's suite or performance benchmark was run. Only a small identifier probe used the actual extracted BookiE helper bodies.

## Findings worth acting on first

### 1. Retry classification is broader than safe stale-plan recovery

BookiE `crates/drivers/postgres/src/query.rs` treats every SQLSTATE `0A000` as a stale type cache. Both query and execute helpers clear statements and retry once; pooled controlled calls enable this path. Dedicated session calls disable it.

PostgreSQL defines `0A000` as general feature_not_supported, not proof that execution never began. A function/trigger can advance a sequence and then raise that code. Sequence advancement is not rolled back. Thus a failed autocommit call may run its nontransactional effect twice. This is a source-backed risk; the native double-dispatch scenario has not been run.

Minimal regression: a disposable sequence and function calling nextval then raising `0A000`; execute once through the guarded pooled path and assert one attempted call using the sequence's native state. A sibling test preserves verified SELECT-star cache invalidation recovery. Repeat for parameterized execution and explicit session behavior. Do not broadly recover from an error code or a user-spoofable message without proof of pre-execution failure.

Origin: [DBeaver duplicate execution report](https://github.com/dbeaver/dbeaver/issues/42013). Its actual root cause is different (25P02 recovery that did nothing), so the external report prompted the check rather than proving BookiE's bug. Native semantics: [error codes](https://www.postgresql.org/docs/current/errcodes-appendix.html), [nontransactional sequence effects](https://www.postgresql.org/docs/current/functions-sequence.html).

### 2. Completion identity erases valid PostgreSQL identifiers

BookiE `completion::table_key` strips quoting and lowercases all components, merging `public.users` and `public."Users"`. `schema_index::split_table_reference` removes every quote before splitting at the last dot; it turns `"odd.schema"."a.b"` into schema `odd.schema.a`, table `b`, and `public."a""b"` into table `ab`.

The isolated helper probe reproduced all three transformations. This establishes a completion/cache routing defect, not a database write to the wrong table. Reuse quote-aware identifier parsing and preserve the exact catalog names. Unquoted names fold according to the engine; quoted names retain identity. pgcli's tests explicitly hold both `users` and `Users` in the same schema: [source](https://github.com/dbcli/pgcli/blob/baf0f01db64e5ed20337eb9c4dee050dabd5705c/tests/test_smart_completion_multiple_schemata.py).

The next useful improvement is search_path-aware resolution and metadata owned by the actual session. The current ambiguity refusal is safe, but it cannot choose the server-visible relation when two schemas have the same bare table name. A second connection does not automatically share SET ROLE, temporary relations or session search_path.

### 3. Extension support needs an explicit per-consumer map

BookiE already has source tests for hstore/ltree text fallback and citext scalar/array behavior. It has sophisticated domain, enum, range and native array cases, including safe composite-array refusal. Those tests were inspected, not rerun.

The file named `vector_contract.rs` covers PostgreSQL system `int2vector` and `oidvector`. It does not qualify pgvector's `vector`, `halfvec` or `sparsevec`. No dedicated pgvector or PostGIS extension fixture/decoder was found. Current generic result fallback is not an extension support guarantee; unsupported binary values generally remain Undecodable, with all-text result paths needing separate qualification.

Start with exact server text or explicit refusal through the existing Value/ColumnInfo contract. Qualify query, grid view/edit, bind, SQL copy, CSV/JSON/XLSX and MCP separately. Add a new representation only when a concrete consumer requires it.

For pgvector, preserve dimension and float4 values, and keep halfvec/sparsevec/bit separate. dbx has a compact decoder and uses shortest f32 decimal formatting: [source](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-driver-postgres/src/postgres.rs). Do not copy its decode-failure-to-NULL fallback, and do not infer support from a type's name alone. [pgvector upstream](https://github.com/pgvector/pgvector) is the wire/behavior reference.

For PostGIS, raw geometry, SRID, dimensions and NULL/EMPTY are distinct. Display WKT alone does not preserve all of them. dbx fixed lost SRID in [#12140](https://github.com/t8y2/dbx/pull/12140); DBeaver's geometry handler separates raw value from display and SRID. Native oracles should use ST_AsEWKB, ST_SRID and dimensions. A map view can wait until exact viewing/copying/rebinding is proven.

## What each client teaches

### pgcli: completion is a model of PostgreSQL visibility

Its metadata stores schema, exact relation spelling, columns, foreign keys, functions and types separately. Tests combine multiple schemas, quoted case, aliases and shadowing. It uses current_schemas(true), so PostgreSQL's implicit schemas matter. Learn the fixture model and context-aware selection; keep BookiE's generation checks.

Its background refresher constructs a new completer and publishes it after refresh. A fix makes column loading tolerate a table appearing between relation and column queries ([#1591](https://github.com/dbcli/pgcli/pull/1591)). Snapshot publication avoids a half-populated UI, but does not create a database snapshot. BookiE must bound background work and preserve owning-session context instead of cloning default connection settings.

Its transaction indicator distinguishes idle, active/open, failed and unknown using protocol status. BookiE currently tracks an open-transaction boolean. A clear failed-transaction indicator with a governed rollback action is a high-value UX idea. Avoid automatic rollback/replay: the user may intentionally inspect or recover with savepoints.

Its forced text loaders preserve BC/out-of-range dates, but applying text to every type would weaken BookiE's typed contract. Borrow the explicit fallback cases, not the whole representation policy. Some pgcli tests use sleeps and current code disables parser grouping bounds; neither is a model to copy into BookiE's bounded/testable architecture.

### pgAdmin: small DDL differences can have real data effects

Three recent fixes provide particularly useful cases:

- [START versus RESTART](https://github.com/pgadmin-org/pgadmin4/pull/10561): changing an identity's configured start must not rewind a sequence already used. last_value and is_called matter; a cached metadata value is not enough.
- [Negative options](https://github.com/pgadmin-org/pgadmin4/pull/10557): a sentinel comparison accidentally dropped valid negative increment/start/min/max values. Missing and negative are different states.
- [Foreign keys after dropped columns](https://github.com/pgadmin-org/pgadmin4/pull/10542): attribute numbers differ between schemas/databases that underwent different DDL. Compare referenced column identities/names semantically; do not compare raw confkey arrays as portable identity.

BookiE currently refuses primary-key/identity toggles on existing columns, so those sequence-edit failures are future regression cases, not current bugs. Keep that refusal until a full edit capability is selected.

pgAdmin also fixed saving expression/alias result columns as base-table columns ([#10329](https://github.com/pgadmin-org/pgadmin4/pull/10329)). BookiE's SQL result grid is currently read-only; keep it that way until base-column provenance, complete row keys and allowed operations are proven. Duplicate aliases and joins require explicit editability decisions.

Its cursor fix separates control commands from server-side result cursors ([#10321](https://github.com/pgadmin-org/pgadmin4/pull/10321)). BookiE's driver already refuses unrelated queries while a forward-only cursor is active; preserve those checks when #809 wires the editor. Test actual transaction state after BEGIN/COMMIT/ROLLBACK, not just a UI completion message.

### DBeaver: capabilities and metadata identity have many edges

The PostgreSQL module is useful for catalog/DDL cases and for separating raw, native export and display values. It is a Java/JDBC/Eclipse implementation, so importing its framework is not useful for BookiE.

- [@? formatter fix](https://github.com/dbeaver/dbeaver/pull/42369): PostgreSQL JSON operators must remain intact even without whitespace before the operator. Also exercise @@, ?|, ?&, casts and named parameter detection.
- [Aggregate regression](https://github.com/dbeaver/dbeaver/issues/42308): array_agg with internal ORDER BY and FILTER is valid server SQL. Unsupported parser syntax should produce an explicit safe result; a parser panic must never enable bypassing PolicyGuard.
- [PUBLIC pseudo-role](https://github.com/dbeaver/dbeaver/pull/42091): PUBLIC is ACL grantee OID 0, not an ordinary pg_roles row. BookiE's grant query already handles OID 0. Do not introduce a second role model just to copy the fix.
- [Timescale capability inheritance](https://github.com/dbeaver/dbeaver/issues/41636): an extension-specific server adapter lost PostgreSQL generated-column support. BookiE does not currently have that adapter split; keep extensions as capabilities of the PostgreSQL driver unless a real protocol difference requires more.
- [Transactional metadata refresh](https://github.com/dbeaver/dbeaver/pull/42101): refresh both source and destination after rename/schema move, honor commit/rollback/savepoints and reject stale refresh generations. BookiE already has catalog epochs; extend its existing coordinator rather than copying DBeaver's much larger implementation.
- [Fetched-row timezone export](https://github.com/dbeaver/dbeaver/issues/42407): display contains a zone while SQL export drops it. BookiE's TimestampTz carrier is a useful foundation; replay exported data under a different TimeZone to prove the instant survives.

### dbx: verify export by restoring it

Its live function-order export test creates source and empty target databases, exports objects whose dependencies cross phases, restores the output and checks native results. This is stronger than asserting generated SQL contains a substring. [Source](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-core/tests/live_postgres_export_function_order.rs).

An index can call a function; a function can return a table row type; a foreign key may refer to a later table. Linear alphabetical ordering does not satisfy all dependencies. For BookiE's later snapshot feature, native pg_dump/pg_restore is a better initial ownership tradeoff than a second handwritten full-database exporter.

Selection must survive every layer: [DBeaver #42329](https://github.com/dbeaver/dbeaver/issues/42329) reports a checked table disappearing from actual pg_dump arguments. Use a fake process boundary to inspect argv and a small native restore to check that an excluded sentinel table stays excluded. Credentials stay out of argv; endpoint, database, TLS identity and tool/server version compatibility must be explicit.

## Inspiration with the best return for a small team

| Idea | First useful slice | Existing owner |
|---|---|---|
| PostgreSQL-aware completion | Correct quoted identity, then search_path/role/temp context | New completion finding; #580 for catalog scaling |
| Visible session health | Show failed transaction and offer guarded rollback; retain server identity | #590 acceptance and headless tab-state work |
| Better EXPLAIN | Structured JSON plans with estimated rows/cost first; later actual/estimated mismatch and buffers | #790 candidate; existing explain_tree is text based |
| Extension-aware value viewer | Exact raw/text preview with type and refusal reason; pgvector dimensions or spatial SRID later | Extension qualification proposal; #610 editor work |
| Useful server messages | Bounded NOTICE stream beside results, with count/byte truncation | #550 |
| Lazy contextual catalog | Fetch only needed schema/table columns; discard stale snapshots | #580 and existing SchemaIndex |
| Reliable backup UX | Native tools, exact selection, cancel/cleanup and verified restore | #547 |

Explain Analyze executes SQL. Never silently turn ordinary Explain into Analyze; retain policy checks for wrapped statements and untrusted plans. Treat plan SQL/predicates as potentially sensitive when exporting or sharing.

## Regression suite without another CI explosion

Use the existing PostgreSQL fixture and tier owners. Select a small packet from cases.csv, not all 46 cases in every pull request. Keep pure parsing/state checks in unit, process argv/negative harness checks in sandbox, stored values/type/transaction facts in driver/release, and only real widget behavior in GTK.

The shared PostgreSQL test server currently relies on a process-local mutex and serial libtest arguments. Nextest's process-per-test model changes that assumption. Its pilot (#892) must preserve fixture isolation or use genuine interprocess ownership before broadening to driver tests. pgAdmin [#10562](https://github.com/pgadmin-org/pgadmin4/pull/10562) shows why shared fixture modifications must be restored after every test.

Prefer explicit temporary database/schema ownership, restore session settings/roles, avoid wall-clock sleeps, and require nonzero executed test identities. Native oracles should be send bytes, pg_typeof, catalog identity, sequence state, server transaction/activity or an independently restored database. A copied formatter cannot serve as its own oracle.

## Adoption order

1. Narrow unsafe retry classification and fix quoted completion identity, with regressions.
2. Qualify one pgvector and one PostGIS exact path/refusal before rich UI or new carriers.
3. Add failed-transaction feedback and the existing bounded NOTICE feature.
4. Extend existing cursor/catalog acceptance with the selected lifecycle cases.
5. Keep native snapshot/restore and deep administration after the current release focus.

No additional runtime dependency is required for the first two correctness fixes. Source reuse is selective and must retain applicable notices; this review did not perform a dependency license/advisory audit.

Verdict: make PostgreSQL identity, execution and session behavior reliable first; borrow the peer clients' minimized fixtures and native replay tests to deepen capability one path at a time.

Not checked: live servers, full external suites, installed GTK/Wayland, extension images, parse/compile benchmarks or every upstream issue. Source coverage is not a fresh runtime pass.

## Recorded GitHub work

- [#900](https://github.com/cozyGarage/BookiE/issues/900)
- [#901](https://github.com/cozyGarage/BookiE/issues/901)
- [#902](https://github.com/cozyGarage/BookiE/issues/902)

Existing issue follow-ups:

- [#790 research follow-up](https://github.com/cozyGarage/BookiE/issues/790#issuecomment-6181432764)
- [#809 research follow-up](https://github.com/cozyGarage/BookiE/issues/809#issuecomment-6181433068)
- [#547 research follow-up](https://github.com/cozyGarage/BookiE/issues/547#issuecomment-6181433300)
- [#550 research follow-up](https://github.com/cozyGarage/BookiE/issues/550#issuecomment-6181433541)
- [#892 research follow-up](https://github.com/cozyGarage/BookiE/issues/892#issuecomment-6181433814)

## Implementation follow-up (2026-10-15)

- Retry recovery: [#900](https://github.com/cozyGarage/BookiE/issues/900), merged [#921](https://github.com/cozyGarage/BookiE/pull/921), with [native reproduction and boundary evidence](../../evidence/2026-10-15-postgres-safe-cache-retry.md).
- Completion identity: [#901](https://github.com/cozyGarage/BookiE/issues/901) and concurrent [#922](https://github.com/cozyGarage/BookiE/pull/922); verified remaining routing work is [#933](https://github.com/cozyGarage/BookiE/issues/933), with [regression evidence](../../evidence/2026-10-15-postgres-completion-routing.md).
- Native completion fixture acceptance is also tracked by [#923](https://github.com/cozyGarage/BookiE/issues/923); tests from [#932](https://github.com/cozyGarage/BookiE/pull/932) are retained in the follow-up.
- CI diagnostic suppression discovered during validation is tracked by [#937](https://github.com/cozyGarage/BookiE/issues/937).
- Actual GTK proposal insertion needs separate qualification in [#934](https://github.com/cozyGarage/BookiE/issues/934).

The original source pins and case status above describe the research snapshot. Use the linked implementation evidence and issue states for subsequent changes.
