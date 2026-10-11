# Oracle review of the value and policy tests (before 0.2.0)

A passing test only says the code agrees with the test. This review asks the
other question: **where did the expected value come from?** If it came from the
database, a standard or a written rule, the test defines the right behaviour. If
it came from the code under test, a green gate proves nothing.

Related: [value contracts](value-contracts.md) (the shared corpus and the rules
for values), [manual verification](manual-verification-0.2-features.md) (the
installed checks this review sits beside) and ledger row TEST-32.

## Oracle classes

| Class | Meaning | Example |
|---|---|---|
| N, native | The database or a standard computes the expected value | `value = 'FFFFFFFF/FFFFFFFF'::pg_lsn AS server_match`, `pg_typeof(value)`, `value::text` in the same query |
| R, round trip | A value goes in and the same value comes out through our code and the engine | the shared corpus in `testdata/value-contract.json` run by `assert_scalar_contract` on every engine |
| H, hand typed | The author typed the expected literal | `assert_eq!(decode(...), "{\"NULL\",...}")` |
| C, computed | The expectation is computed by the code under test, or by a copy of its algorithm | an expected string built with the same formatter the driver uses |
| P, policy | The expected decision comes from an ADR, `AGENTS.md` or a written rule | "TRUNCATE needs approval in Local" |

N and P are strong. R is strong against loss but blind to symmetric errors (the
code stores a value wrongly and reads it back wrongly the same way), so every R
test needs one manual native check, which is Part B. H is acceptable when the
literal is checked once against the real engine, with the command recorded. C is
weak and should be replaced.

Verdict for each test: **OK**, **WEAK** (right idea, fragile or one-sided),
**WRONG** (the expectation is not what the engine or the rule says) or
**UNKNOWN** (needs a person to decide).

## Part A: sample sheet for the lane owners

B3 fills the value rows and B4 the policy rows. Read the test, find where each
expected value comes from, then fill the last three columns. The sample was drawn
across engines and areas, and the same procedure then applies to the other
value-contract tests (457 of them). A pull request that adds a test names its
oracle class in the description.

| # | Area | Test (file:line) | What it asserts | Class | Verdict | Notes |
|---|---|---|---|---|---|---|
| 1 | All engines, scalars | `core/tests/support/value_contract.rs` `assert_scalar_contract`, run by `value_contract_preserves_scalar_boundaries_through_parameters_and_exports` in each driver | The 10 integers, 8 floats, 11 texts and 6 decimals in `testdata/value-contract.json` survive a parameter and a literal export | R | OK | `value_contract.rs:5-99` loads `testdata/value-contract.json` and compares bind (`:84-90`) and literal export (`:91-98`) to the same corpus value. Strong against loss; Part B still needed for symmetric encode/decode errors. |
| 2 | PostgreSQL | `drivers/postgres/tests/support/value_contracts.rs:478` `value_contract_pg_lsn_maximum_preserves_text_and_wire_identity` | `pg_lsn` max keeps its text, native type name and wire bytes; the server confirms equality | N | OK | `value_contracts.rs:483-498`: `pg_typeof`, `value::text`, `encode(pg_lsn_send(...))` and `value = 'FFFFFFFF/FFFFFFFF'::pg_lsn AS server_match` are computed by PostgreSQL. |
| 3 | PostgreSQL | `drivers/postgres/tests/support/value_contracts.rs:106` `value_contract_wide_numeric_csv_round_trips_through_native_insert_plan` | A 40-digit `numeric(65,0)`, a narrow value and NULL survive CSV export and import | R | OK | `value_contracts.rs:106-183`: values travel CSV export → import plan → insert; final check uses server `amount::text` (`:171-182`). Plan row carriers at `:159-166` are hand-typed text of those same digits. |
| 4 | PostgreSQL | `drivers/postgres/src/array.rs:464` `value_contract_enum_array_labels_quote_null_text_and_preserve_sql_null` | Enum array labels `NULL`, empty, `a,b`, `a"b`, `東京` and a real SQL NULL render as one array literal | H | WEAK | `array.rs:464-482`: expected `{"NULL","","a,b","a\"b","東京",NULL}` is author-typed against synthetic wire bytes; no live `array_out` / `::text` server oracle in this unit test. |
| 5 | SQL Server | `app/tests/support/mssql_datetimeoffset_contract.rs:8` `value_contract_mssql_datetimeoffset_grid_edit_preserves_local_time_offset_and_siblings` | Editing a `datetimeoffset` cell keeps the local time, the offset and the neighbouring cells | N | OK | `mssql_datetimeoffset_contract.rs:44-58,125-126`: `DATEPART(TZOFFSET, value)` and `CONVERT(varbinary(20), value)` come from SQL Server; after keyed edits the full row set must equal the before snapshot. |
| 6 | DuckDB | `drivers/duckdb/tests/integration.rs:162` `value_contract_native_temporals_round_trip_parameters_and_sql` | Dates before 1970, after year 9999, BC dates, `24:00:00`, nanosecond timestamps and infinity round trip | N | OK | `integration.rs:187-209`: pass/fail is DuckDB's `CAST(literal AS kind) AS VARCHAR = CAST(source AS VARCHAR)` (and the same for bound `?`), not a hand-typed formatted string. |
| 7 | ClickHouse | `drivers/clickhouse/tests/integration.rs:648` `value_contract_ambiguous_datetime64_local_time_is_refused` | A `DateTime64` in an ambiguous local hour (DST) is shown as undecodable, not guessed, and cannot be turned into a literal | N | OK | `integration.rs:651-668` (and Lord Howe `:676-698`): `toString(stamp)` and `toUnixTimestamp64Milli(stamp)` are server columns; the cell must be `Undecodable` and refuse literal/bind (product rule, [known limitations](known-limitations.md)). |
| 8 | MySQL / MariaDB | `drivers/mysql/tests/support/enum_sql_mode_contract.rs:453` `value_contract_mariadb_empty_enum_and_set_csv_restore_survive_empty_string_is_null` | Empty `ENUM` and `SET` values survive a CSV restore under the Oracle-style empty-string-is-NULL mode | N | OK | `enum_sql_mode_contract.rs:515-553` and restore `:584-632`: `CAST(col + 0 AS CHAR)`, `HEX(col)` and `col IS NULL` are MariaDB oracles before and after CSV restore under `EMPTY_STRING_IS_NULL`. |
| 9 | MongoDB | `drivers/mongodb/tests/support/value_contracts.rs:869` `value_contract_binary_subtypes_survive_native_grid_edits` | Binary subtypes are kept when a document is edited from the grid | N | OK | `value_contracts.rs:885-973`: seed and post-edit check use the native `mongodb` crate (`insert_one` / `find_one`) for subtype and bytes, not only the driver result. |
| 10 | SQLite | `drivers/sqlite/tests/integration.rs` `sqlite_real_storage_preserves_float_edge_bits` | The smallest subnormal, the maximum, and both infinities keep their exact bits | R | OK | `integration.rs:1027-1055`: bits are inserted through our binder and compared on read (`to_bits`); `typeof(value)` is native (`real`) but the float oracle is round-trip, not an independent SQL literal insert. |
| 11 | Export | `core/src/export/file.rs:182` `value_contract_xml_illegal_text_preserves_destination_and_reports_coordinates` | Text XML cannot hold is refused with its row and column and the destination file is untouched | N | OK | `file.rs:185-208`: characters are those XML 1.0 forbids; error must name `row 2, column 2` and the codepoint; destination bytes stay `existing XML`. |
| 12 | Policy | `policy/tests/aud11_s6_s7.rs` `truncate_needs_human_approval_even_when_local_ddl_is_permissive` | `TRUNCATE` needs approval in Local even when ordinary DDL does not | P | OK | `aud11_s6_s7.rs:69-74`: Local defaults have `human_approve_ddl == false`, yet `TRUNCATE TABLE users` must be `RequireApproval` (AUD-11 / [effects proposal](proposals/policy-effects-and-verdict.md)). |
| 13 | Policy | `policy/src/select_writes.rs:18` `select_into_creates_a_table_and_is_a_write` | `SELECT ... INTO` is classified as a write | P | OK | `select_writes.rs:18-28`: postgres/mssql `SELECT ... INTO` must report `writes()` and not `StatementClass::Select` (table-creating select is a write). |
| 14 | Policy / drivers | `drivers/postgres/tests/support/read_only_session.rs:16` `a_read_only_connection_is_refused_writes_by_the_server` | A read-only connection is refused writes by the server itself, not by our check | N | OK | `read_only_session.rs:32-42`: writes fail with PostgreSQL SQLSTATE `25006`; a plain `SELECT` still returns the row, so the refusal is the server's read-only transaction. |

How to answer a row quickly:

1. Open the test and list every expected literal or expression.
2. For each, write where it comes from: the server (N), the corpus (R), your own
   typing (H), the code under test (C) or a rule (P, with the rule's link).
3. If it is H, say whether it was checked against the real engine, and how.
4. Put WEAK or WRONG rows in the ledger with the file and line.

## Part B: real values by hand (maintainer and UX lane)

This is the first pass and it is manual, so it belongs with the installed checks
before 0.2.0. The point is to see the value the database really stores, without
our code in between.

For each engine you can reach (PostgreSQL, MySQL or MariaDB, SQL Server, SQLite,
DuckDB, ClickHouse, MongoDB), use its own client and a scratch table or
collection:

1. Create a table with the engine's native types for an integer, a float, a
   decimal and a text column.
2. Insert the values below with the native client, so our code is not involved.
3. Read them back with the native client and note the exact text it prints.
4. Open the same table in the app and compare the grid cell, the cell's value
   dialog and a CSV export to the native text.
5. Edit one value in the grid, save it, and read it back with the native client.
   The stored value must be the one you typed.
6. Record the result next to each line, never blank.

Values (from `testdata/value-contract.json`):

| Kind | Values to check |
|---|---|
| Integer | `-9223372036854775808`, `-9007199254740993`, `9007199254740993`, `9223372036854775807` |
| Float | `0.1`, `1.0000000000000002`, `1e-200`, `1e200` |
| Decimal | `0.00000001`, `1.23000000` (trailing zeros kept), `99999999999999999999.99999999` |
| Text | empty string, `NULL` (the word), `O'Brien`, `漢字 😀 é`, `ends in \`, a line break and a tab, and SQL NULL |

The three cases people get wrong are worth looking at first: the word `NULL`
versus an empty string versus real NULL, a decimal whose trailing zeros must
stay, and an integer above 2^53 that must not pass through a float.

Result record, one row per engine and kind:

| Engine | Kind | Native client printed | App grid showed | CSV export | Edit and save read back | Result | Date and build SHA |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

## Part C: mock rows (examples, not results)

These two rows only show how to fill the sheets. They are not records of a run.

Part A, mock for row 2:

| 2 | PostgreSQL | `value_contracts.rs:478` | `pg_lsn` max keeps text, type and wire bytes | N | OK | The query returns `pg_typeof` and `server_match` from the server itself, so the expectation is the server's own answer. |

Part B, mock for a PostgreSQL decimal:

| PostgreSQL | decimal | `1.23000000` | `1.23000000` | `1.23000000` | typed `4.50000000`, read back `4.50000000` | pass | 2026-10-11, build `abcdef0` |

## After the first pass

- Fill Part A for the sample, then extend it to the rest of the value-contract
  tests by area: B3 for values, B4 for policy.
- Every WEAK or WRONG row becomes a ledger row or a small test pull request.
- Every Part B failure is a product bug: record it in the ledger with the engine,
  the value and what each side showed.
