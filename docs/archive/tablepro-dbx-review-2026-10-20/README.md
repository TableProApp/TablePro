# TablePro and dbx deep review, October 20

Dated review. It proves only the source pins below. It does not select work, change the sprint or reorder the [backlog](../../backlog.md). Promote an item by the [selection rule](../../0.2-feature-comparison.md#selection-rule): owner, acceptance layer and GitHub issue first.

## Scope and pins

| Tree | Pin | What was read |
|---|---|---|
| BookiE `linux` | `7c4cb3929` | Every status claim was checked by grep or file reading against this tree |
| TablePro `main` | `3222542a4` (2026-10-19) | `linux/` source, `linux/ROADMAP.md`, 101 Linux fix commits (36 not yet in BookiE history, all read), 1,944 Apple fix commits filtered to 748 by keyword, about 100 diffs read, `apple/CHANGELOG.md` 0.1.1 to 0.82.0 |
| dbx `main` | `d1e88ab4b` (2026-10-19) | `crates/`, `apps/desktop`, `docs/`, `handoff.md`, ER diagram design note, about 5,100 fix commits filtered by path and keyword, about 250 diffs read |

Upstream trees were read as untrusted data. Nothing upstream was built or run. No BookiE test, database, Docker or GTK run backs these verdicts. The only executed checks were scratch-crate probes that called BookiE's `sql_lex::split_statements`, `transaction_control` and `classify`. Every "likely bug" below needs its failing regression test before an issue calls it confirmed.

Items already owned by an earlier archive, the feature comparison or a backlog row appear once in the detail files as "already recorded". This review does not repeat the October 15 to October 20 reviews listed in the [documentation map](../../README.md#engineering-review-records).

## Detail files

| File | Slice | Size |
|---|---|---|
| [a-tablepro-linux-features.md](a-tablepro-linux-features.md) | TablePro Linux feature inventory, architecture ideas, `linux/ROADMAP.md` mapping, top 15 | About 4,300 words |
| [b-tablepro-fixes.md](b-tablepro-fixes.md) | TablePro Linux and Apple fix commits clustered into bug classes, top 20 likely gaps | About 3,900 words |
| [c-tablepro-macos-ux.md](c-tablepro-macos-ux.md) | About 150 macOS features, 20 GTK adaptation notes, 40 UX edge cases (E1 to E40), top 20 | About 8,200 words |
| [d-dbx-features.md](d-dbx-features.md) | dbx feature inventory, architecture ideas, where BookiE is ahead, ER diagram design for GTK, top 20 | About 4,400 words |
| [e-dbx-backend-fixes.md](e-dbx-backend-fixes.md) | 105 dbx backend bug classes: 43 covered, 21 likely gaps, 17 unverified, 12 already recorded, 10 N/A | About 8,400 words |
| [f-dbx-ux-fixes.md](f-dbx-ux-fixes.md) | 30 dbx UX bug classes and dbx UX features BookiE lacks, top 15 | About 2,600 words |

Each detail table row carries the upstream commit or changelog version, the BookiE path, a verdict, a proposed test with its tier, a lane and a priority.

## BookiE contracts relevant to adaptation

Preserve the following contracts when evaluating an external implementation.

- Typed values under [ADR 0007](../../decisions/0007-type-and-value-preservation.md). dbx carries decimals and datetimes as JSON strings in cells.
- One `PolicyGuard` path for the GUI, MCP and `bookie-agentd`, with terminal audit states and fail-closed masking. dbx's SQL guard and timed write unlock sit beside its execution path, not under it.
- Scoped MCP tokens, connection allowlists and rate limits. The MCP server is stdio only; `agentd` refuses network bind flags.
- Server-confirmed cancellation where the engine supports it (ADR 0005).
- Secrets only in Secret Service, never in connection JSON.
- Static driver crates, with no JDBC sidecar, plugin runtime or web mode.
- Bounded PostgreSQL streaming and bounded result caps elsewhere.
- Real-engine driver tests, installed GTK tests and a mutation audit.
- Most of TablePro Linux's feature set is already present, plus MCP, Redis, MongoDB, DuckDB, backup and Vim mode.

## Wave 0: defects to confirm and fix first

These come from upstream fixes whose BookiE equivalent reads as broken. "Hand-checked" means the review lead re-read the cited BookiE code after the slice reviewer reported it. Others were re-read by the slice reviewer only.

### P1

| # | Defect | BookiE evidence | Lane | Source | Hand-checked |
|---|---|---|---|---|---|
| 0.1 | Ctrl+Enter or Ctrl+Shift+Enter during a running query starts a second run. Only the Run button is made insensitive; `begin_run` has no running guard and cancels the first run locally, so a write script can apply twice or end Unknown | `apps/linux/app/src/ui/editor/split_view.rs:71`, `ui/editor/mod.rs:696,776`, `ui/editor/run_lifecycle.rs:28`, `ui/editor/mod.rs:992-996` | UX | dbx `d51b92998` ([f](f-dbx-ux-fixes.md)) | Yes |
| 0.2 | Connection URL import drops `?sslmode=` and saves `TlsMode::Disabled`, then stores the password. `postgres://u@db/app?sslmode=require` becomes plaintext. A storage test pins the Disabled default | `crates/storage/src/connection_url.rs:62,111-112,303-312` | B4 | TablePro and dbx ([b](b-tablepro-fixes.md), [e](e-dbx-backend-fixes.md)) | Yes |
| 0.3 | A missing SQLite file silently becomes a new empty database; DuckDB likewise. A moved or mistyped path reports success | `crates/drivers/sqlite/src/lib.rs:71-79` (`create_if_missing(!read_only)`), `crates/drivers/duckdb/src/lib.rs:247` | B3, UX | TablePro Linux, dbx | Yes (SQLite) |
| 0.4 | Every TLS error, including a failed certificate check, tells the user to set TLS to Disabled | `apps/linux/app/src/ui/error_text.rs:31-32` | B4, UX | TablePro `linux/crates/core/src/tls_failure.rs` | Yes |
| 0.5 | Version metadata disagrees before 0.2.0 publication: app crate `0.2.0`, meson `0.1.6-dev`, newest metainfo release `0.1.5` | `apps/linux/app/Cargo.toml:3`, `meson.build:1`, `apps/linux/flatpak/com.tablepro.linux.metainfo.xml:51` | UX | TablePro `check_packaging.py` | Yes |
| 0.6 | ClickHouse grid edits key on the non-unique sorting key and skip the checked write, so one edit can change several rows | `crates/drivers/clickhouse/src/lib.rs:558`, `row_ops.rs:252` | B3 | TablePro Linux | No |
| 0.7 | SQLite Drop Table runs with foreign keys on and no inbound-key check, so dropping a parent cascades into child tables | `apps/linux/app/src/ui/app/structure.rs:123` | B3, UX | TablePro | No |
| 0.8 | MySQL `utf8mb4_bin` text and MariaDB JSON decode as Bytes; the vendored sqlx keys on the BINARY flag and only ENUM and SET were patched | `vendor/sqlx-mysql`, `crates/drivers/mysql/src/decode.rs:66-68` | B3 | TablePro Apple | No |
| 0.9 | MySQL `CALL` takes columns from the prepare step and loses result sets; the error-1295 text retry returns no rows and reports success | `crates/drivers/mysql/src/lib.rs:598-616`, `session.rs:142-158` | B3 | dbx | No |
| 0.10 | The shared-connection rule reads the trailing `END` of trigger and routine bodies as `Commit` and refuses valid DDL. This is a refusal, not a bypass. A probe reproduced it on SQLite, MySQL, SQL Server and PostgreSQL `BEGIN ATOMIC` | `crates/policy/src/rules.rs:101` | B4 | dbx | Probe |
| 0.11 | ClickHouse users with `readonly=1` likely cannot connect, because every request sets `mutations_sync=1` | `crates/drivers/clickhouse/src/lib.rs:89` | B3 | dbx | Setting present; server behaviour not run |
| 0.12 | Redis browse runs GET, HGETALL or SMEMBERS on whole values for each page row, with no byte bound | `crates/drivers/redis/src/lib.rs:359-391` | B3 | dbx | No |

### P2

| Defect | BookiE evidence | Lane |
|---|---|---|
| Copying rows and pasting into another BookiE grid changes data: formula-leading text gains `"'` and NULL becomes the text `\N`; paste does not reverse the export guards | `crates/core/src/export/csv.rs:95,119,247`, `apps/linux/app/src/ui/browse_tab/paste.rs` | UX, B3 |
| Restore keeps only the first `MAX_TABS_PER_CONNECTION` tab records; later editor tabs lose their only copy of the query without a warning | `apps/linux/app/src/services/workspace_state.rs:543` (hand-checked) | UX |
| Window shortcuts (Ctrl+W, F5, Ctrl+S) may act on the tab behind an open dialog | `apps/linux/app/src/ui/app/shortcuts.rs:131` (unverified) | UX |
| A FIFO or device used as CA, certificate or key hangs connect; the file is opened before the regular-file check | `crates/transport/src/session_material.rs:109` | B4 |
| MySQL `CLONE ... IDENTIFIED BY 'pw'` is kept in history in plain text | `crates/core/src/sql_credentials.rs:94-103` | B4 |
| The MCP failed-login budget is charged before the token is verified, so any local process can lock out a valid token | `crates/mcp/src/bridge.rs:131` | B4 |
| ClickHouse uses bundled webpki roots when no CA is named; corporate CAs in the system store are ignored. MongoDB and Redis need the same check | `crates/drivers/clickhouse/src/tls.rs:54` (hand-checked) | B4 |
| PostgreSQL pooled `SET search_path`, `SET TIME ZONE` and temp tables leak across the four pooled connections | `crates/drivers/postgres/src/lib.rs:126-131` | B4 |
| One server-text column switches the whole PostgreSQL statement to text, after which `infinity`, BC dates and `24:00` fail to decode | `crates/drivers/postgres/src/query.rs:85-87` | B3 |
| A UTF-8 BOM SQL file classifies as `Unparseable` | `crates/core/src/text_file.rs:51` | B3 |
| MongoDB `authSource` always equals the selected database | `crates/drivers/mongodb/src/lib.rs:101-111` | B4 |
| One non-UTF-8 Redis collection member fails the whole page | `crates/drivers/redis/src/lib.rs:367-382` | B3 |
| DuckDB cancel does not interrupt the query although the crate exposes `interrupt_handle()` | `crates/drivers/duckdb/src/lib.rs:771` | B4 |
| SQL Server TDS routing redirects (Azure SQL, AG read-only routing) are not followed | `crates/drivers/mssql/src/lib.rs:969` | B4 |
| MySQL lenient `sql_mode` silently truncates or coerces grid saves and imports; warnings are never read | `crates/drivers/mysql/src` | B3 |
| `USE` on a pooled MySQL connection sticks, so catalog reads can list another database | `crates/drivers/mysql/src/lib.rs:97-101,540-548` | B4, B3 |
| A MySQL `DEFAULT (uuid())` is restated without parentheses on column edit | `crates/drivers/mysql/src/lib.rs:833-835` | B3 |
| MySQL LIKE filters assume backslash escaping and miss rows under `NO_BACKSLASH_ESCAPES` | `crates/core/src/filter.rs:422-424` | B3 |
| MongoDB filters on ObjectId and long fields bind strings and never match | `crates/core/src/filter.rs:583-595` | B3 |
| MongoDB grid edits of field names containing `.` or `$` write nested or invalid paths | `crates/drivers/mongodb/src/update.rs:584-593` | B3 |
| A fraction finer than `timestamp(0)` or `DATETIME(0)` rolls the value on save; precision is checked only for SQL Server | `apps/linux/app/src/ui/browse_tab/value_parse.rs:222-249` | B3 |
| The inline and JSON editors load multi-MB values on the GTK thread with no budget | `apps/linux/app/src/ui/grid/editing.rs:23-25,426-430` | UX |
| Redis and MongoDB commands containing `key:name` open the parameter dialog, then fail | `crates/core/src/params.rs:102` | UX |

Three further items are asserted by current BookiE tests and need B3 agreement before any test changes: PostgreSQL serial ids dropped from SQL export, MySQL sessions forced to UTC on non-UTC servers, and the CSV decimal-comma option rewriting text such as `3.40`. P3 items are in the detail files.

## Feature roadmap candidates

Ranked by daily value for the [personas](../../personas.md), fit with the governed-MCP product choice, and cost. Effort is S, M or L. Lanes follow [AGENTS.md](../../../AGENTS.md#lanes-and-ownership).

### Wave 1: small and medium daily-use items

| # | Feature | Upstream | Lane | Effort |
|---|---|---|---|---|
| 1.1 | Run the selected text with Ctrl+Enter when a selection exists | dbx | UX | S |
| 1.2 | CTE and derived-table names in completion | dbx | UX | M |
| 1.3 | Back and Forward per browse tab after FK navigation | TablePro macOS | UX | M |
| 1.4 | FK preview popover on a reference cell | TablePro macOS | UX | S |
| 1.5 | Desktop and CLI open: SQLite MimeType, `%U`, `HANDLES_OPEN`, new-window action | TablePro Linux and macOS | UX | S-M |
| 1.6 | Explicit New SQLite or DuckDB file in the connection form, paired with 0.3 | TablePro | UX, B3 | S |
| 1.7 | Recent and starred tables in the sidebar | TablePro macOS | UX | S |
| 1.8 | Restore per-tab caret, page, scroll and sort | TablePro macOS | UX | S |
| 1.9 | Multi-column sort in browse | TablePro macOS | UX, B3 review | M |
| 1.10 | SQL snippets through `GtkSourceSnippet`, including favorite keywords | dbx, TablePro macOS | UX | S |
| 1.11 | Copy as UPDATE, WHERE clause and JSON lines, through `sql_literal.rs` | dbx | B3, UX | S |
| 1.12 | URL import for `mongodb+srv`, `rediss` and file URLs; Copy Connection URL without secrets | dbx, TablePro macOS | UX | S |
| 1.13 | MCP client configuration snippet in MCP preferences | TablePro macOS | UX | S |
| 1.14 | Inhibit logout and suspend while edits are unsaved or a save or export writes; guard quit during export | TablePro Linux | UX | S |
| 1.15 | Wake the connection monitor on network change and resume | TablePro Linux | UX | S |
| 1.16 | Renameable editor tabs with stable numbers | dbx | UX | S |
| 1.17 | Paste that extends into new draft rows, clearing identity columns | dbx | UX | S |
| 1.18 | Redo action, Set Empty, Size to Fit columns, style scheme picker | TablePro | UX | S |
| 1.19 | Changed-on-disk notice for open `.sql` files (`GFileMonitor` with `AdwBanner`) | TablePro macOS | UX | S |
| 1.20 | History recording off switch and delete history with a connection | TablePro Linux | UX | S |

### Wave 2: medium features

| # | Feature | Upstream | Lane | Effort |
|---|---|---|---|---|
| 2.1 | MCP and audit activity window: read the audit journal and MCP calls in the GUI | TablePro macOS | UX, B4 | M |
| 2.2 | Editable row inspector (`AdwEntryRow` form) | TablePro macOS | UX | M |
| 2.3 | JSON tree viewer with filter in the value viewer | TablePro macOS | UX | M |
| 2.4 | Set Value menu: DEFAULT, `NOW()`, UUID. Needs a typed expression value from B3 first | TablePro macOS | B3, UX | M |
| 2.5 | Display As per column (binary UUID, epoch integer) | TablePro macOS | B3 | M |
| 2.6 | Import connections from DBeaver, DataGrip and Beekeeper, without secrets | TablePro macOS, dbx | UX, B4 | M |
| 2.7 | JSON import, then XLSX through `calamine`, with error modes and a skipped-rows report | dbx, TablePro macOS | UX, B3 | M |
| 2.8 | Destructive DDL review before type changes, drops and multi-step saves | TablePro Linux | B3, UX | M |
| 2.9 | MCP read-only discovery tools (routines, routine source, schema context) and a per-token tool allowlist | dbx | B4 | M |
| 2.10 | Function signature help for PostgreSQL, DuckDB and ClickHouse | dbx | UX | M |
| 2.11 | Save a BLOB to a file and load one from a file, bounded, through the portal file chooser | dbx | UX | M |
| 2.12 | Opt-in continue-after-error for scripts, with policy and audit per statement | dbx | UX, B4 | M |
| 2.13 | Startup SQL per connection, run through PolicyGuard | TablePro macOS | B4 | M |

### Wave 3: large features

| # | Feature | Notes | Lane |
|---|---|---|---|
| 3.1 | Read-only ER diagram | Keep model, relationship inference, layout and Mermaid/DBML export GTK-free and unit tested. Infer edges from FKs, then `*_id` naming, then type compatibility; users confirm or ignore each one per connection, database and schema. Grid layout first, then a Sugiyama layout in Rust. Draw with Cairo and Pango on a `DrawingArea`, with a list view for screen readers. Any later DDL goes into an editor tab so PolicyGuard applies. See [d](d-dbx-features.md#4-er-diagram-design-for-gtk) | UX, B3 |
| 3.2 | Same-engine schema compare report that writes a reviewed script into the editor. Report committed, rolled back or mixed per statement; never verify by re-running a commit (dbx `handoff.md`) | B3 |
| 3.3 | SQLite table rebuild for changes `ALTER TABLE` cannot express. BookiE refuses those changes today | B3 |
| 3.4 | Data transfer between connections | After 3.2 and ADR 0014 export decisions | B3, B4 |

## Architecture and tooling to adopt

| Idea | Upstream | Where in BookiE | Lane |
|---|---|---|---|
| One static dialect profile per grammar used by the splitter, classifier, completion and export. Extends PEER-2 / #893 and would close 0.10 and the splitter disagreement | dbx `SqlDialectProfile` | `crates/core` `sql_syntax`, `sql_lex` | B3, B4 review |
| DDL rules as data per driver (quoting, auto-increment, comments, rename syntax), ending `driver_id` string matches | dbx `DdlDialectProfile` | `crates/core` `sql_ddl`, `sql_dialect` | B3 |
| Static `DriverCapabilities` struct instead of scattered `supports_*` methods. Feeds APP-MOD | dbx manifest, as a Rust struct not YAML | `crates/core` driver traits | B3 |
| Typed `TlsFailure` with a safe remedy per kind. Closes 0.4 | TablePro Linux | `crates/core`, `crates/transport`, `error_text.rs` | B4, UX |
| One rustls configuration with the platform verifier for every driver | TablePro Linux `rustls-platform-verifier` | `crates/transport` | B4 |
| One JSON policy-verdict corpus read by both `crates/policy` and `crates/mcp` tests | dbx shared safety corpus | `crates/policy/tests`, `crates/mcp/tests` | B4 |
| Release metadata check: Cargo, meson, metainfo and CHANGELOG versions agree. Closes 0.5 | TablePro `check_packaging.py` | `scripts/` | UX |
| `deny.toml`: `yanked = "deny"`, `wildcards = "deny"`, scoped `rsa` wrappers, preventive bans | TablePro Linux | `deny.toml` | UX |
| Workspace lints `ignore_without_reason` and `unsafe_op_in_unsafe_fn` now; `allow_attributes_without_reason` with a ratchet (163 bare `#[allow]` today) | TablePro Linux | `Cargo.toml` workspace lints | UX |

## Do not adopt

- dbx's JSON-as-cell value model, YAML dialect hot reload, split `dbx-sql-*` crates, web mode, plugin runtime, JDBC sidecars and AI chat.
- dbx connection-management and plugin MCP tools, and its timed write unlock unless a new ADR amends [ADR 0016](../../decisions/0016-governed-consumer-seam.md).
- TablePro Apple-only services, license gates, Sparkle, AppleScript, iCloud and Oracle, as already recorded in the [feature comparison](../../0.2-feature-comparison.md#explicitly-out-of-scope-unless-product-goals-change).
- SSH ProxyCommand and SOCKS5 without a separate threat review.

## Stale text found during the review

The [upstream history](../upstream-sync-history-2026-10-22.md#2026-09-19-re-survey-after-upstream-rewrote-its-linux-branch) records the earlier no-askpass finding and its correction. Commit `8ed7647c4` reconciled the wording against the current source; this dated review note is retained as the original observation.

## Suggested promotion order

1. File each Wave 0 P1 as a lane issue with its failing regression test named, starting with 0.1, 0.2, 0.3 and 0.4, which were hand-checked. 0.5 blocks publication hygiene and is small.
2. Take the P2 security rows (FIFO CA, `CLONE` history, MCP lockout, trust store) to B4 together.
3. Select Wave 1 items into the backlog in small UX slices; 1.1, 1.5, 1.6 and 1.14 are the cheapest wins.
4. Start the dialect profile and DDL profile before Wave 3, because the ER diagram, schema compare and completion all depend on them.
