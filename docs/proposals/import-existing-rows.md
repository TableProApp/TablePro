# Proposal: import into rows that already exist

Status: proposal, not scheduled. Source: TablePro PR 3743 (update, upsert and insert-skip-existing import modes), found in the October 22 upstream review. Nothing here is built.

## Today

CSV and `.xlsx` import ([dialog](../../apps/linux/app/src/ui/import_dialog.rs), [planner](../../crates/core/src/import/plan.rs)) has two modes, `ExistingTable` and `NewTable`. Both only insert. `build_insert_plan` returns one `InsertPlan`: a single INSERT statement shape plus every row's bound values, so one approval covers the whole file. A key that already exists makes the database refuse the row, and the transaction rolls back.

## The gap

Someone reloading a corrected export, or syncing a lookup table, has to delete first or write SQL by hand. Three modes would cover that:

| Mode | Existing key | New key |
|---|---|---|
| Insert only (today) | error, whole import rolls back | insert |
| Skip existing | leave the row alone | insert |
| Update existing | overwrite the mapped columns | error or skip (decision 2) |
| Upsert | overwrite the mapped columns | insert |

## Constraints that shape the design

1. **One plan, one approval.** An upsert must stay one statement shape for the whole file. A per-row "does it exist" query would break that and make the approved SQL differ from what runs.
2. **A key is required.** Update and upsert need the conflict columns. The primary key is the default. A table without one must refuse these modes, as the grid does for deletes (known limitations: no all-column fallback, by design). A unique index could be offered later; not in a first version.
3. **Statement shape differs per engine**, and each needs a failing-before test against a real server:
   - PostgreSQL and SQLite: `ON CONFLICT (<key>) DO UPDATE SET ... / DO NOTHING`.
   - MySQL and MariaDB: `ON DUPLICATE KEY UPDATE ...` and `INSERT IGNORE` (which also hides unrelated errors; prefer a no-op update of the key column for skip).
   - SQL Server: no single-statement equivalent short of `MERGE`. The current classifier keeps `MERGE` on its fail-closed unknown-write path ([regression](../../crates/policy/src/classify/tests.rs)); confirm its approval and audit behavior before considering SQL Server support.
   - ClickHouse, MongoDB, Redis, DuckDB: not assumed; each would need its own check. First version should list supported engines explicitly and refuse the rest.
4. **Policy and audit.** The statement class changes (an upsert is both insert and update). `PolicyGuard` must classify it as the stricter of the two, show it in the approval dialog, and write one audit entry. Confirm this against `crates/policy` before building; do not assume.
5. **Values keep their contract.** Bound values, the MySQL empty-string handling and `OVERRIDING SYSTEM VALUE` for identity columns already live in `build_insert_plan`. The new modes must reuse that binding, not fork it (ADR 0007).
6. **Outcome reporting.** Today the result is a row count. With conflicts the user needs "inserted N, updated M, skipped K". Engines report this differently (MySQL counts an update as 2; PostgreSQL's `RETURNING (xmax = 0)` distinguishes insert from update). Decide whether to report exact counts or only "N rows affected".
7. **Duplicate keys inside the file.** Two file rows with the same key in one upsert behave differently per engine (PostgreSQL raises "cannot affect row a second time"). Detect and refuse before executing.

## Decisions needed

1. Which engines in the first version. Suggested: PostgreSQL, SQLite, MySQL/MariaDB.
2. Whether update-existing refuses or skips rows whose key is new. Suggested: refuse, because a silent skip loses data.
3. How exact the outcome report must be (constraint 6).
4. Whether the import dialog or a separate step chooses the key columns. Suggested: primary key only, shown read-only.

## Proposed order

1. Pure planner: `build_upsert_plan` per engine with statement-text unit tests, the same style as the existing plan tests.
2. Duplicate-key-in-file refusal and keyless-table refusal, with tests.
3. Policy classification check, with a test that the approval dialog receives the combined class.
4. Real-server contract tests for each engine (Docker), including re-importing the same file twice.
5. Dialog: mode selector shown only when the table has a primary key and the engine is supported.
6. Docs: user guide, known limitations, changelog.

## Not covered

Merging into a different target than the table being imported, matching on non-key columns, and deleting rows missing from the file (a full sync). Each is a separate, riskier feature.
