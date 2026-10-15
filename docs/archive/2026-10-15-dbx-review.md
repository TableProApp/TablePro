# dbx and BookiE: architecture, adoption and defect review

Reviewed 2026-10-15. This is a source review with two isolated probes, not release qualification. No BookiE product files or dependencies were changed during the source review. Follow-up issues are listed below.

## Evidence and scope

| Source | Pin and method |
| --- | --- |
| BookiE local checkout | `d906624642a28f3a2a35bdec3578607458315c49`; clean checkout at the start. Read architecture, active sprint, accepted ADRs, current limitations, and relevant app, core, driver and MCP paths. |
| dbx main | `12139b55df9b4bf0ae89d4fab459bf1871e8a783`; shallow clone with 350 recent commits. Reviewed workspace manifests, architecture guards and selected implementations and fix diffs. |
| dbx GitHub history | Screened 300 recent issue/PR feed records and 100 recently updated closed PR records, checked merge timestamps, and read selected bodies. Also queried cancellation history, which returned 21 issue records. This is a sample, not an exhaustive review of their tracker or 8,396 commits. |
| Probes | Compiled BookiE's actual dependency-free script lexer modules in a temporary Rust executable. Ran a JavaScript JSON parse example for a large integer. No database, desktop or full workspace suite was run. |

Assumed use: one developer with multiple tabs and connections, sometimes to production databases, using large values and occasional MCP automation. Multi-user web hosting is not a BookiE requirement.

Evidence labels below mean:

- **Confirmed source gap:** the implementation establishes the missing behavior. Runtime impact is qualified separately.
- **Probe reproduced:** an isolated check demonstrated the particular failure, without claiming full app or database reproduction.
- **Existing tracked limitation:** already recorded by BookiE; do not create duplicate work.
- **Future regression case:** an external failure worth testing if the corresponding feature is implemented; not a claim that BookiE currently has the bug.

## Assessment

dbx is useful inspiration for shared application orchestration, explicit capabilities, bounded operation lifecycles and focused tests. It is not evidence that an architecture or package is bug-free. Recent merged fixes address wrong numeric summaries, BSON type changes, cancellation that did not stop statements, stale commit callbacks and exports using the wrong transaction.

BookiE should preserve its typed values, bound SQL values, static drivers and PolicyGuard. Adapt dbx's useful patterns into those boundaries. Importing its backend wholesale would bring a different product architecture and value model.

## Architecture comparison

The key naming difference: dbx's `core` is an application orchestrator. BookiE's `core` is its domain and driver contract leaf. Do not move orchestration into BookiE core to imitate the name.

| Responsibility | dbx | BookiE adoption route |
| --- | --- | --- |
| Desktop and other entry points | Vue/Tauri frontend; web, CLI and MCP consumers | GTK/Relm4 app and headless agentd/MCP |
| Application orchestration | `dbx-core`, with connection, query, schema, data, persistence and safety directories | Continue accepted ADR 0018 extraction into `tablepro-app-services`; preserve PolicyGuard at ADR 0016's consumer seam |
| Domain and serialized data | `dbx-types` | `tablepro-core`; keep native value distinctions |
| SQL libraries | `dbx-sql-core`, dialect, data and schema crates, re-exported by `dbx-sql` | Existing `core::sql_syntax`, `sql_dialect`, `sql_ddl`, import and export modules; extract only when a real dependency or build problem justifies it |
| Database execution | Native driver crates plus driver support, driver aggregator and agent/JDBC paths | Existing static driver crates, transport and SSH |
| File encoders | `dbx-formats` | Existing core export/import modules and `rust_xlsxwriter` |
| UI backend seam | `apps/desktop/src/lib/backend/api.ts` dispatches to Tauri or HTTP | Shared headless services exercised by GTK and agentd; no need for an HTTP adapter inside the desktop app |

Sources: [dbx architecture](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/ARCHITECTURE.md), [backend facade](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/apps/desktop/src/lib/backend/api.ts), BookiE `ARCHITECTURE.md`, ADRs 0016 and 0018.

There is a cost to avoid copying: at this pin, dbx's `DataGrid.vue` is 16,975 lines and `queryStore.ts` is 10,487 lines. It has 1,530 desktop `*.spec.ts` files, but that count proves neither coverage quality nor correctness. Its extracted helpers and boundary tests are more useful models than its largest components.

## What to adopt

### 1. Enforce dependency boundaries in automation

dbx's `scripts/core-architecture.test.mjs` reads Cargo metadata and checks an explicit allowed dependency map, including build and development dependencies. It also checks production test hooks and feature forwarding. This catches drift that a directory diagram cannot prevent.

BookiE already documents the same direction, but this review did not find an equivalent dependency allowlist guard under `scripts/`. Add a small metadata check for the existing boundaries, especially no GTK/glib/Relm4 dependency in app-services and no application dependency in drivers or core. Put it in the existing preflight path. Do not copy dbx's checks for exact filenames and source text unless BookiE needs those particular contracts.

Source: [architecture guard](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/scripts/core-architecture.test.mjs).

### 2. Complete the shared headless application seam

dbx delegates application workflows through one core and tests the frontend against a backend seam. BookiE already has the direction in ADRs 0016/0018 and an initial app-services crate. Continue that work where it removes real duplicated behavior: tab lifecycle transitions, request ownership and workflow orchestration.

For GTK tests, use a fake core connection behind a real PolicyGuard. This lets tests schedule delayed results, cancellation and failures without replacing the rules being tested. Keep GTK callbacks responsible for rendering and native widget handshakes.

### 3. Preserve structured outcomes through MCP

dbx's versioned backend error distinguishes operation outcome, transaction outcome, subsystem and stable code. BookiE already has useful `DriverError` variants, including `OperationOutcomeUnknown`, but MCP turns them into strings.

Adapt a small stable MCP error representation from BookiE's own error types. The important field is whether a write definitely did not start or may already have happened. Do not copy the large JDBC-specific error catalog or adopt a string marker protocol to carry typed fields.

Source: [backend error envelope](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-driver-agent/src/backend_error.rs).

### 4. Distinguish cancellation request from confirmed completion

dbx's running-query registry tracks execution and registration identity, runs late interrupt handles immediately after an earlier cancellation request, and exposes `{requested, terminal}`. The registration identity prevents an old guard's destruction from removing a newer execution with the same public ID.

BookiE's `run_server_cancellable` already requires server confirmation and reports unknown outcomes otherwise. Keep that stronger behavior. Borrow the registry test sequences and UI distinction between stopping, stopped and outcome unknown. A dropped future, removed registry item or aborted task is not server confirmation.

Source: [query cancellation lifecycle and tests](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-core/src/query/query_cancel.rs).

### 5. Use explicit capability data where lists drift

dbx has a shared database manifest, pagination strategies and DDL profiles. The profiles represent choices such as quoting, identity syntax and index placement as data.

BookiE already exposes capability methods through `DatabaseDriver`. Extend those methods when a real feature needs them and derive UI availability from them. Do not introduce dbx's 100-engine registry, dynamic dialect loading or runtime plugins. A static descriptor can fit BookiE's current architecture without changing its driver model.

Sources: [database manifest](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-types/src/database_manifest.rs), [DDL profiles](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-sql-dialect/src/sql_dialect/ddl_profile.rs).

### 6. Borrow bounded server output and action metadata

dbx's query message buffer limits both count and total bytes, and flushing does not reset the operation's total budget. That is a useful design for BookiE's tracked NOTICE/PRINT work, UI-20/#550. A future GTK adapter must also have a bounded delivery queue and preserve the result set when notices arrive first.

Its shortcut registry records action identity, label, scope and defaults together. BookiE already has `WINDOW_SHORTCUTS`; extend the existing table to feed help and command search if they drift. Avoid a second registry.

Sources: [bounded query messages](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-driver-support/src/query_messages.rs), [shortcut registry](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/apps/desktop/src/lib/editor/shortcutRegistry.ts), [notice-before-result fix](https://github.com/t8y2/dbx/pull/12059).

## Package and code reuse decisions

| Candidate | Decision |
| --- | --- |
| `dbx-core`, `dbx-drivers` | Do not import wholesale. They bring application state, dynamic runtimes and a different driver/result contract. |
| `dbx-types` | Do not replace BookiE's typed domain model. Its JSON boundary helpers are useful examples for MCP interoperability. |
| `dbx-sql-core` / `dbx-sql-dialect` | Study regression inputs and small algorithms. Internal types and build-generated dialect/connection resources make this more than a drop-in parser dependency. Keep one BookiE SQL contract. |
| `dbx-formats` | A relatively independent leaf crate, but not an immediate win. BookiE already has CSV/JSON/SQL/XLSX and a maintained XLSX writer; dbx's custom XLSX machinery would add ownership. |
| WKB geometry helper | A possible source reference if spatial support is selected. Preserve raw geometry and SRID; review parser size/depth bounds before adapting it. Do not add spatial features only to reuse the code. |
| `calamine` | Worth evaluating if XLS/XLSX/ODS import becomes approved work. dbx uses it; BookiE currently has no direct dependency. Keep ZIP expansion, cells, rows and memory bounded, and retain explicit import conversion errors. |
| `cargo-nextest` | Worth a measured CI experiment for isolated Rust tests. Do not replace installed GTK, keyring, Docker or Forgejo acceptance, and do not infer speed from dbx's choice. |
| `sqlparser` | Already shared by both projects. BookiE pins 0.58 and dbx 0.62 at the reviewed sources. Evaluate an upgrade against actual failures and policy classification behavior; a newer parser is not automatically a safer policy. |
| `encoding_rs` | Evaluate only for approved non-UTF-8 input support. It is already transitive in BookiE's lockfile, which does not make it a direct API dependency. Silent replacement decoding would violate value preservation. |
| `russh`, `rust_decimal`, `serde_json`, Tokio, tempfile | Already in BookiE. No dependency addition is needed to copy the relevant patterns. |

Most reviewed dbx leaf crates explicitly set `publish = false`. Treat them as internal workspace libraries rather than stable independently released packages. If selected code is adapted, pin its source and retain applicable source/license notices. No dependency license or advisory audit was performed because nothing was added.

Sources: [workspace manifest](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/Cargo.toml), [formats manifest](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-formats/Cargo.toml), [core manifest](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-core/Cargo.toml), [calamine upstream](https://github.com/tafia/calamine), [dbx architecture and nextest workflow](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/ARCHITECTURE.md).

## Findings in current BookiE

### Must fix

1. **MongoDB metadata can exceed the result memory budget before a small query runs.** Confirmed source gap; memory failure was not runtime reproduced.

   - **What this is:** `crates/drivers/mongodb/src/lib.rs:199-236` samples the first 128 whole documents to infer columns. `run_find:518` does this before executing the user's find.
   - **Problem:** Line 226 collects all sampled documents into a `Vec` without a byte budget. A collection with 128 roughly 8 MiB documents retains roughly 1 GiB of BSON payload, plus overhead, even for a find limited to one row. The later 64 MiB result check does not protect this allocation.
   - **Fix:** Stream the sample cursor and update the type map one document at a time. Bound schema cardinality and retained page bytes too; a row count is not a byte bound. Preserve existing mixed-type refusals.
   - **If skipped:** Wide documents can cause severe memory spikes or process termination, losing unsaved UI work.
   - **Regression case:** Wide metadata sample plus a one-row find; measure peak memory and preserve inferred types. dbx's [wide JSONB export hang #7087](https://github.com/t8y2/dbx/issues/7087) motivates checking intermediate buffers, but is not the same root cause.

2. **Valid MySQL scripts are rejected when the session disables backslash escapes.** Probe reproduced with BookiE's actual lexer; full database flow not run.

   - **What this is:** `apps/linux/app/src/ui/editor/statement_cursor.rs:16-17` always uses grammar defaults; `core/src/sql_syntax/script/lexical_settings.rs` defaults MySQL backslash escaping to true.
   - **Problem:** After `SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'`, the valid script `SELECT 'path\'; SELECT 2;` has two statements. BookiE's default lexer reports one statement and an unterminated string. `script_statements:38-39` refuses it. Cursor selection, folding, formatting and completion also use default settings.
   - **Fix:** Derive lexical settings from the actual owning session, and propagate them consistently. If the app cannot represent a changed mode safely, explicitly refuse that mode rather than assuming defaults. Mid-script changes need a deliberate rule because the whole script is currently planned before execution. Review PostgreSQL `standard_conforming_strings` and MySQL `ANSI_QUOTES` in the same scope.
   - **If skipped:** Valid scripts fail or statement targeting disagrees with server parsing. This review did not prove a policy bypass.
   - **Probe output:** escaping=true: 1 statement, unterminated string at byte 7; escaping=false: 2 statements, no diagnostics.
   - **Regression case:** Actual session-mode changes, run-all and run-current-statement, with a harmless second statement. dbx [#11951](https://github.com/t8y2/dbx/pull/11951) and [#11780](https://github.com/t8y2/dbx/pull/11780) show why splitting and cursor selection must agree.

### Should fix

3. **MCP large integers are unsafe for ordinary JavaScript consumers.** Confirmed source representation plus a reproduced client conversion; conditional interoperability defect.

   - **What this is:** `crates/mcp/src/tools.rs:313` emits every `Value::Int` as a JSON number; line 324 passes nested JSON through unchanged. Query, browse, explain and JSON export use this conversion.
   - **Problem:** A JavaScript consumer parsing `9007199254740993` gets `9007199254740992`. The JSON text remains exact and a lossless parser works, so this is not a Rust driver or native grid precision defect. MCP content is returned as text; the risk arises when a client parses that result with ordinary JavaScript JSON handling.
   - **Fix:** Define an explicit lossless MCP representation for wide integers and nested numeric values, with type metadata or tagged values as needed. Preserve the normal file-export contract. This is a public contract change governed by ADR 0007, not a global stringify operation.
   - **If skipped:** A consumer can feed a rounded ID into a later operation and target the wrong row.
   - **Regression case:** ±(2^53+1), i64 limits and nested JSON through the real response and a JavaScript parser. dbx's [JSON boundary helper](https://github.com/t8y2/dbx/blob/12139b55df9b4bf0ae89d4fab459bf1871e8a783/crates/dbx-types/src/json.rs) addresses this boundary; [#12078](https://github.com/t8y2/dbx/pull/12078) fixes a separate summary conversion of otherwise exact values.

4. **MCP tool discovery omits safety annotations.** Confirmed source gap.

   - **What this is:** Both `crates/mcp/src/server.rs:243-253` and `rmcp_server.rs:59-63` advertise tools without annotations.
   - **Problem:** Clients cannot discover which tools the server declares read-only or potentially destructive. dbx had the same reported friction in [#12154](https://github.com/t8y2/dbx/issues/12154), fixed by merged [#12185](https://github.com/t8y2/dbx/pull/12185).
   - **Fix:** Add one shared annotation definition and use it in both transports. Declare arbitrary write tools conservatively, including preview paths with engine-specific side effects. Keep token scopes, allowlists and PolicyGuard authoritative.
   - **If skipped:** Some clients show unnecessary approvals or poor tool descriptions. Missing annotations do not by themselves bypass BookiE security.
   - **Regression case:** Assert emitted tools/list annotations for both implementations and retain denied-call tests.

5. **MCP erases machine-readable write uncertainty.** Confirmed source gap; unsafe client retry is a scenario, not an observed BookiE replay.

   - **What this is:** `crates/mcp/src/bridge.rs:452-482` returns `Result<WriteOutcome, String>` and stringifies driver errors. The rmcp adapter exposes failures as text content.
   - **Problem:** A lost acknowledgement after a committed write becomes an error whose text says outcome unknown, but the client has no stable field to distinguish it from a write that never started. Rollback failure also lacks a structured transaction outcome.
   - **Fix:** Preserve a small stable error code and operation/transaction outcome through the existing MCP boundary. Do not add automatic write replay. Preserve compatibility or version the response where required.
   - **If skipped:** Automation must parse prose or risk duplicating a write after an ambiguous failure.
   - **Regression case:** Commit succeeds but acknowledgement is lost; response says unknown, no replay occurs, and audit records the terminal state. Reuse the existing timeout/audit fixtures and owner of TEST-15/#593.

## dbx fixes and issues mapped to BookiE

| External evidence | What it teaches | BookiE status or follow-up |
| --- | --- | --- |
| [#11950 BSON numeric edits](https://github.com/t8y2/dbx/pull/11950) | Int32 and whole-number Double must not become Int64 during editing. | Already addressed in the inspected path: `browse_tab/value_parse.rs:431` wraps Int32 as `$numberInt`; codec restores it. Keep native BSON type assertions. Do not report the generic `Value::Int -> Int64` helper as a GUI bug without tracing this caller. |
| [#12078 exact summaries](https://github.com/t8y2/dbx/pull/12078) | An exact driver value can become rounded in a later UI helper. | Browse selection stats use Decimal for integer/decimal totals and checked addition. XLSX writes wide integers and decimals as text. Preserve this behavior; MCP needs separate boundary work above. |
| [stale commit fix](https://github.com/t8y2/dbx/commit/e9b6e5fcb89c6fd87a9e474687cad85566862dcc) and [#11780](https://github.com/t8y2/dbx/pull/11780) | Old commit callbacks must not clear a new session, and repeated clicks must not dispatch twice. | `session_mode.rs:466-510` already checks ending-session identity and matches completion callbacks. No equivalent current defect established. Add close/reopen/switch sequences when extracting the tab model. |
| [export in active transaction fix](https://github.com/t8y2/dbx/commit/c8816364f7c3284fca7a842cf923d37b6018584a) | A new connection cannot export a temporary table or uncommitted state from the old session. | Current loaded-result export avoids rerunning the query. Full-table export is refused under ADR 0014. Future export must keep session, snapshot and stable order. |
| [#12141 false paging](https://github.com/t8y2/dbx/pull/12141) | SHOW/EXPLAIN results must not get a pager that reruns the whole statement. | Editor results are materialized; no identical bug established. Preserve statement classification and identity when wiring ADR 0011 cursors. |
| [#12165 unnecessary Mongo count](https://github.com/t8y2/dbx/pull/12165) | Indexed LIMIT 50 should not wait for a full matching count. | Inspected `run_find` has no separate exact count. Its metadata sample still adds work and creates finding 1. Do not add count-all as a prerequisite for first paint. |
| [JDBC stop fix](https://github.com/t8y2/dbx/commit/6a1778eaf385c7c8a52276c03202c1763427df65), [#8414 SQLite tab stuck after cancel](https://github.com/t8y2/dbx/issues/8414) | Test the next operation after stopping, not only the cancelled future. | Existing OperationControl already models uncertainty. Same-tab SELECT 1, session usability and late callback cases remain useful acceptance sequences. SQL Server server-side cancellation is explicitly open as #850. |
| [#12191 export quoting](https://github.com/t8y2/dbx/pull/12191) | A generic Standard SQL label does not make quoting executable on MySQL. | BookiE SQL export delegates to engine-specific literal/identifier builders with existing quoting tests. No same defect established. Preserve native replay tests. |
| [#12140 lost spatial SRID](https://github.com/t8y2/dbx/pull/12140) | WKT text alone is not the full spatial value. | Future regression case if spatial support is added. Do not turn an undecodable geometry into editable display text. |
| [#12202 long SQL Server copy](https://github.com/t8y2/dbx/issues/12202) | SQL copy must use full data and safe long-string expressions. | Open user report, not a confirmed shared root cause. BookiE emits a whole N-prefixed text literal, not dbx's same implementation. Test long Unicode, quotes and supplementary characters by native replay if extending this path. |
| [#12108 idle connection hang](https://github.com/t8y2/dbx/issues/12108) | Idle sessions, locks and reconnects can fail after days of use. | Open report; root cause not established. Test BookiE's monitor/reconnect and active transaction behavior without automatically replaying writes. |
| [#12160 repeated PostgreSQL SQL-file failure](https://github.com/t8y2/dbx/issues/12160) | File execution should preserve session and transaction lifecycle across DDL and reruns. | Open report; do not label it a parser or driver fix without evidence. Adapt the reported migration to a disposable database when SQL-file acceptance is next run. |
| [#7087 stalled wide-row backup](https://github.com/t8y2/dbx/issues/7087), [#7314 excluded table still exported](https://github.com/t8y2/dbx/issues/7314) | Bound stream cleanup and filter objects before executing their reads. | Future snapshot implementation under #547 must test exclusion, cancellation, temporary output cleanup and restart behavior. These features are not currently shipped, so these are future tests rather than present BookiE defects. |

## Suggested order

1. B3: fix metadata sample retention and add a representative wide-document case. Keep row-result and metadata budgets separate and bounded.
2. UX/B4: decide and implement session-aware script parsing, including policy consistency and mode changes within scripts.
3. B3/B4: define lossless MCP numeric and structured error contracts, updating both transports and consumers together.
4. B4: add shared tool annotations. This is a small implementation with no new dependency.
5. UX: add a Cargo dependency-boundary guard and continue the already accepted headless tab-state extraction.
6. Follow the active sprint for SQL Server cancel, installed Wayland qualification, materialized-result memory and snapshot/export work. Reuse existing issues and lane ownership.

Verdict: adopt dbx's boundary checks, explicit outcomes and regression scenarios. Preserve BookiE's current type and policy contracts. Fix metadata memory and session-mode parsing first.

Not checked: complete dbx source/history, live database reproductions, installed GTK/Wayland flows, dependency advisories, benchmarks or release acceptance. The two probes prove only their stated parser and JavaScript behaviors.

## Recorded follow-up work

The research was published on GitHub and is now retained here with the [PostgreSQL follow-up](2026-10-15-postgresql-client-research/review.md). Architecture principles and guards are tracked by [#891](https://github.com/cozyGarage/BookiE/issues/891) and [#887](https://github.com/cozyGarage/BookiE/issues/887), the nextest pilot by [#892](https://github.com/cozyGarage/BookiE/issues/892), lexical settings by [#893](https://github.com/cozyGarage/BookiE/issues/893), bounded Mongo metadata by [#894](https://github.com/cozyGarage/BookiE/issues/894), MCP wide integers by [#895](https://github.com/cozyGarage/BookiE/issues/895), explicit operation outcomes by [#896](https://github.com/cozyGarage/BookiE/issues/896), and MCP annotations by [#897](https://github.com/cozyGarage/BookiE/issues/897).
