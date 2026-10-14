# Oracle review of the value and policy tests (before 0.2.0)

A passing test only says the code agrees with the test. This review asks the other question: **where did the expected value come from?** If it came from the database, a standard or a written rule, the test defines the right behaviour. If it came from the code under test, a green gate proves nothing.

Related: [value contracts](value-contracts.md) (the shared corpus and the rules for values), [manual verification](manual-verification-0.2-features.md) (the installed checks this review sits beside) and ledger row TEST-32.

## Oracle classes

| Class | Meaning | Example |
|---|---|---|
| N, native | The database or a standard computes the expected value | `value = 'FFFFFFFF/FFFFFFFF'::pg_lsn AS server_match`, `pg_typeof(value)`, `value::text` in the same query |
| R, round trip | A value goes in and the same value comes out through our code and the engine | the shared corpus in `tests/data/value-contract.json` run by `assert_scalar_contract` on every engine |
| H, hand typed | The author typed the expected literal | `assert_eq!(decode(...), "{\"NULL\",...}")` |
| C, computed | The expectation is computed by the code under test, or by a copy of its algorithm | an expected string built with the same formatter the driver uses |
| P, policy | The expected decision comes from an ADR, `AGENTS.md` or a written rule | "TRUNCATE needs approval in Local" |

N and P are strong. R is strong against loss but blind to symmetric errors (the code stores a value wrongly and reads it back wrongly the same way), so every R test needs one manual native check, which is Part B. H is acceptable when the literal is checked once against the real engine, with the command recorded. C is weak and should be replaced.

Verdict for each test: **OK**, **WEAK** (right idea, fragile or one-sided), **WRONG** (the expectation is not what the engine or the rule says) or **UNKNOWN** (needs a person to decide).

## Part A: sample sheet for the lane owners

B3 fills the value rows and B4 the policy rows. Read the test, find where each expected value comes from, then fill the last three columns. The sample was drawn across engines and areas, and the same procedure then applies to the rest of the value-contract tests. A pull request that adds a test names its oracle class in the description.

| # | Area | Test (file:line) | What it asserts | Class | Verdict | Notes |
|---|---|---|---|---|---|---|
| 1 | All engines, scalars | `crates/core/tests/support/value_contract.rs` `assert_scalar_contract`, run by `value_contract_preserves_scalar_boundaries_through_parameters_and_exports` in each driver | The 10 integers, 8 floats, 11 texts and 6 decimals in `tests/data/value-contract.json` survive a parameter and a literal export | R | WEAK | `value_contract.rs:5-99` loads `tests/data/value-contract.json` and compares bind (`:84-90`) and literal export (`:91-98`) to the same corpus value. This catches loss but can miss symmetric encoder/decoder errors; Part B's native-client check is still pending. |
| 2 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:544` `value_contract_pg_lsn_maximum_preserves_text_and_wire_identity` | `pg_lsn` max keeps its text, native type name and wire bytes; the server confirms equality | N | OK | `value_contracts.rs:549-564`: `pg_typeof`, `value::text`, `encode(pg_lsn_send(...))` and `value = 'FFFFFFFF/FFFFFFFF'::pg_lsn AS server_match` are computed by PostgreSQL. |
| 3 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:106` `value_contract_wide_numeric_csv_round_trips_through_native_insert_plan` | A 40-digit `numeric(65,0)`, a narrow value and NULL survive CSV export and import | N | OK | `value_contracts.rs:106-183`: the CSV path carries values through import, and the final `amount::text` comes from PostgreSQL (`:171-182`). Plan row carriers at `:159-166` are hand-typed; the database text is the independent final oracle. |
| 4 | PostgreSQL | `crates/drivers/postgres/src/array.rs:464` `value_contract_enum_array_labels_quote_null_text_and_preserve_sql_null`; `crates/drivers/postgres/tests/support/array_contract_parts/enum_array_file_consumers.rs` `value_contract_custom_enum_array_file_exports_preserve_labels` | Enum array labels `NULL`, empty, `a,b`, `a"b`, `東京` and a real SQL NULL render and rebind without changing their values | H | OK | The unit expectation `{"NULL","","a,b","a\"b","東京",NULL}` is hand-typed against synthetic wire bytes. The native PostgreSQL test rebinds the driver's text and compares `array_to_json` and `array_send` with server results. PostgreSQL quotes some enum labels differently in `::text`; equivalent valid text is accepted when native values and wire bytes match. |
| 5 | SQL Server | `apps/linux/app/tests/support/mssql_datetimeoffset_contract.rs:8` `value_contract_mssql_datetimeoffset_grid_edit_preserves_local_time_offset_and_siblings` | Editing a `datetimeoffset` cell keeps the local time, the offset and the neighbouring cells | N | OK | `mssql_datetimeoffset_contract.rs:44-58,125-126`: `DATEPART(TZOFFSET, value)` and `CONVERT(varbinary(20), value)` come from SQL Server; after keyed edits the full row set must equal the before snapshot. |
| 6 | DuckDB | `crates/drivers/duckdb/tests/integration.rs:162` `value_contract_native_temporals_round_trip_parameters_and_sql` | Dates before 1970, after year 9999, BC dates, `24:00:00`, nanosecond timestamps and infinity round trip | N | OK | `integration.rs:187-209`: pass/fail is DuckDB's `CAST(literal AS kind) AS VARCHAR = CAST(source AS VARCHAR)` (and the same for bound `?`), not a hand-typed formatted string. |
| 7 | ClickHouse | `crates/drivers/clickhouse/tests/integration.rs:648` `value_contract_ambiguous_datetime64_local_time_is_refused` | A `DateTime64` in an ambiguous local hour (DST) is shown as undecodable, not guessed, and cannot be turned into a literal | P | OK | `integration.rs:651-668` (and Lord Howe `:676-698`): refusal follows the documented ambiguous-time limitation; `toString(stamp)` and `toUnixTimestamp64Milli(stamp)` establish the native input. |
| 8 | MySQL / MariaDB | `crates/drivers/mysql/tests/support/enum_sql_mode_contract.rs:453` `value_contract_mariadb_empty_enum_and_set_csv_restore_survive_empty_string_is_null` | Empty `ENUM` and `SET` values survive a CSV restore under the Oracle-style empty-string-is-NULL mode | N | OK | `enum_sql_mode_contract.rs:515-553` and restore `:584-632`: `CAST(col + 0 AS CHAR)`, `HEX(col)` and `col IS NULL` are MariaDB oracles before and after CSV restore under `EMPTY_STRING_IS_NULL`. |
| 9 | MongoDB | `crates/drivers/mongodb/tests/support/value_contracts.rs:869` `value_contract_binary_subtypes_survive_native_grid_edits` | Binary subtypes are kept when a document is edited from the grid | N | OK | `value_contracts.rs:885-973`: seed and post-edit check use the native `mongodb` crate (`insert_one` / `find_one`) for subtype and bytes, not only the driver result. |
| 10 | SQLite | `crates/drivers/sqlite/tests/integration.rs` `sqlite_real_storage_preserves_float_edge_bits` | The smallest subnormal, the maximum, and both infinities keep their exact bits | R | WEAK | `integration.rs:1027-1055`: bits are inserted through our binder and compared on read (`to_bits`); `typeof(value)` confirms native REAL storage but not an independently inserted float. The manual native-client check in Part B is pending. |
| 11 | Export | `crates/core/src/export/file.rs:182` `value_contract_xml_illegal_text_preserves_destination_and_reports_coordinates` | Text XML cannot hold is refused with its row and column and the destination file is untouched | N | OK | `file.rs:185-208`: characters are those XML 1.0 forbids; error must name `row 2, column 2` and the codepoint; destination bytes stay `existing XML`. |
| 12 | Policy | `crates/policy/tests/aud11_s6_s7.rs` `truncate_needs_human_approval_even_when_local_ddl_is_permissive` | `TRUNCATE` needs approval in Local even when ordinary DDL does not | P | OK | `aud11_s6_s7.rs:69-74`: Local defaults have `human_approve_ddl == false`, yet `TRUNCATE TABLE users` must be `RequireApproval` (AUD-11 / [effects proposal](proposals/policy-effects-and-verdict.md)). |
| 13 | Policy | `crates/policy/src/select_writes.rs:23` `select_into_creates_a_table_and_is_a_write` | `SELECT ... INTO` is classified as a write | P | OK | `select_writes.rs:23-34`: postgres/mssql `SELECT ... INTO` must report `writes()` and not `StatementClass::Select` (table-creating select is a write). |
| 14 | Policy / drivers | `crates/drivers/postgres/tests/support/read_only_session.rs:16` `a_read_only_connection_is_refused_writes_by_the_server` | A read-only connection is refused writes by the server itself, not by our check | N | OK | `read_only_session.rs:32-42`: writes fail with PostgreSQL SQLSTATE `25006`; a plain `SELECT` still returns the row, so the refusal is the server's read-only transaction. |

### PostgreSQL cases from issue #590
| 15 | PostgreSQL | `crates/drivers/postgres/tests/support/native_oracle_contract.rs` `value_contract_integer_text_and_bytea_match_native_oracles` | Integer and text boundaries, plus NULL/empty/binary `bytea`, match PostgreSQL's native type, text, wire and byte outputs | N | OK | `pg_typeof`, `::text`, `int8send`, `octet_length`, `convert_to` and `encode` are computed by PostgreSQL. Includes signed bounds, integers beyond 2^53, empty text, literal `NULL`, apostrophe, Unicode, SQL NULL, empty bytea and binary bytes. |
| 16 | PostgreSQL | `crates/drivers/postgres/tests/integration.rs:838` `value_contract_numeric_digits_scale_and_special_values_survive_decoding`; `crates/drivers/postgres/tests/support/value_contracts.rs:106` `value_contract_wide_numeric_csv_round_trips_through_native_insert_plan` | Wide and special NUMERIC values keep digits and scale through query, binding and CSV | N | OK | The query returns the decoded numeric plus PostgreSQL's `numeric::text`; the CSV test checks persisted `amount::text`. |
| 17 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:978` `value_contract_dates_preserve_eras_large_years_and_instants`; `:986` `value_contract_times_preserve_midnight_fraction_and_offset` | DATE, TIME, TIMESTAMP and TIMESTAMPTZ values preserve boundaries and instants | N | OK | PostgreSQL supplies native `::text` and temporal `*_send` bytes across session time zones and boundary values. |
| 18 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:11` `value_contract_intervals_preserve_independent_fields_in_every_style` | Interval months, days and microseconds remain independent under all supported styles | N | OK | `interval_send` is the server wire oracle; expected bytes are independently assembled from the three source fields. |
| 19 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:583` `value_contract_uuid_domain_preserves_uuid_across_consumers` | UUID and UUID-domain values preserve identity through result, literal and bound paths | N | OK | PostgreSQL supplies the domain `pg_typeof` and `::uuid::text` values for the initial result and both write paths. |
| 20 | PostgreSQL | `crates/drivers/postgres/tests/support/native_oracle_contract.rs` `value_contract_json_and_jsonb_match_native_type_oracles` | JSON and JSONB keep their distinct native semantics and decode as structured JSON | N | OK | PostgreSQL supplies JSON `::text`, `json_typeof`, `jsonb_typeof` and a native JSONB equality result. |
| 21 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:994` `value_contract_arrays_preserve_elements_dimensions_and_exports` | Arrays preserve elements, NULLs, dimensions, bounds and value through binding/export | N | OK | The array fixture asks PostgreSQL for `array_send` and `array_to_json` oracles and compares the rebound value; textual quoting may differ while the native value remains equal. |
| 22 | PostgreSQL | `crates/drivers/postgres/tests/support/enum_contract_parts/scalar_consumers.rs` `value_contract_scalar_enum_labels_preserve_exact_text`; `crates/drivers/postgres/tests/support/array_contract_parts/enum_array_file_consumers.rs` `value_contract_custom_enum_array_file_exports_preserve_labels` | Enum labels, empty and literal `NULL`, Unicode and SQL NULL stay distinct | N | OK | PostgreSQL supplies `enumlabel`, `pg_typeof`, `::text`, JSON and wire results; the array contract compares native JSON and `array_send` after rebinding. |
| 23 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:583` `value_contract_uuid_domain_preserves_uuid_across_consumers`; `:626` `value_contract_jsonb_domain_keeps_json_null_distinct_from_sql_null`; domain-over-enum cases in `domain_contract.rs` | Domains retain base values, declared domain type and NULL distinctions | N | OK | `pg_typeof`, base-type casts, JSON kind/null predicates and persisted values are computed or checked by PostgreSQL. |
| 24 | PostgreSQL | `crates/drivers/postgres/tests/support/range_scalar_contract.rs` `value_contract_builtin_range_scalars_refuse_lossy_writes_and_preserve_rows`; `crates/drivers/postgres/tests/support/range_array_contract.rs` range refusal tests | `int4range` and `int8range` read as the server text; the other built-in and custom ranges remain visible as unsupported, with no lossy literal/bind or row mutation | N | OK | PostgreSQL `pg_typeof`, `::text`, `range_send`/`array_send` and before/after native row snapshots are the oracle; the result is visibly `Undecodable`. |
| 25 | PostgreSQL | `crates/drivers/postgres/tests/support/value_contracts.rs:943` `value_contract_composite_result_is_explicitly_unsupported`; `crates/drivers/postgres/tests/support/custom_array_contract.rs` `value_contract_custom_composite_array_refusal_preserves_rows` | Composite values and arrays are visibly refused and cannot be rebound or written | N | OK | PostgreSQL supplies `pg_typeof`, `row_to_json`, field projections and `array_to_json`; tests require `Undecodable` and preserve stored rows. |

How to answer a row quickly:

1. Open the test and list every expected literal or expression.
2. For each, write where it comes from: the server (N), the corpus (R), your own typing (H), the code under test (C) or a rule (P, with the rule's link).
3. If it is H, say whether it was checked against the real engine, and how.
4. Put WEAK or WRONG rows in the ledger with the file and line.

## Part B: real values by hand (maintainer and UX lane)

This is the first pass and it is manual, so it belongs with the installed checks before 0.2.0. The point is to see the value the database really stores, without our code in between.

For each engine in the 0.2.0 promise that you can reach (PostgreSQL, MySQL or MariaDB, SQL Server, SQLite, DuckDB, ClickHouse, MongoDB and Redis), use its native client and scratch data: a table, collection or key/value entry as appropriate.

1. Create scratch data with native integer, float, decimal and text values where the engine supports those types. For Redis, seed string keys with text and binary values, and use a counter command for an integer reply.
2. Seed the applicable values below with the native client, so our code is not involved.
3. Read them back with the native client and note the exact text it prints.
4. Open the data in the app and compare its value display and CSV export to the native result. Use the grid for tables and the query editor for command-oriented engines.
5. Change a value through the app path that the engine supports, then read it back with the native client. The stored value must be the one you entered.
6. Record the engine, value kind and operation beside each result; never leave a result blank.

Values (from `tests/data/value-contract.json`):

| Kind | Values to check |
|---|---|
| Integer | `-9223372036854775808`, `-9007199254740993`, `9007199254740993`, `9223372036854775807` |
| Float | `0.1`, `1.0000000000000002`, `1e-200`, `1e200` |
| Decimal | `0.00000001`, `1.23000000` (trailing zeros kept), `99999999999999999999.99999999` |
| Text | empty string, `NULL` (the word), `O'Brien`, `漢字 😀 é` (decomposed `e` + U+0301), `ends in \`, a line break and a tab, and SQL NULL |

The three cases people get wrong are worth looking at first: the word `NULL` versus an empty string versus real NULL, a decimal whose trailing zeros must stay, and an integer above 2^53 that must not pass through a float.

Redis has no SQL columns or SQL NULL. For its row, compare an empty string, the text `NULL`, Unicode text, a binary string such as `ff 00 41`, a missing-key response and an integer command reply. Run `SET` and `GET` through the app's command editor, export the loaded query result as CSV, then verify the stored bytes with the native client. Do not treat a missing key and an empty value as the same case.

Result record, one row per engine and kind:

| Engine | Kind | Native client printed | App showed | CSV export | Write/edit read back | Result | Date and build SHA |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

## Part C: mock rows (examples, not results)

These two rows only show how to fill the sheets. They are not records of a run.

Part A, mock for row 2:

| 2 | PostgreSQL | `value_contracts.rs:544` | `pg_lsn` max keeps text, type and wire bytes | N | OK | The query returns `pg_typeof` and `server_match` from the server itself, so the expectation is the server's own answer. |

Part B, mock for a PostgreSQL decimal:

| PostgreSQL | decimal | `1.23000000` | `1.23000000` | `1.23000000` | typed `4.50000000`, read back `4.50000000` | pass | 2026-10-11, build `abcdef0` |

## After the first pass

- Fill Part A for the sample, then extend it to the rest of the value-contract tests by area: B3 for values, B4 for policy.
- Every WEAK or WRONG row becomes a ledger row or a small test pull request.
- Every Part B failure is a product bug: record it in the ledger with the engine, the value and what each side showed.
