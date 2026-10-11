# Historical record: value-contracts.md

Archived 2026-10-03 from `0cf70382eed72c144ea94208dfef5f5706e0a7dd`. The original content below preserves
dated decisions, commands, test counts and source evidence. Its words such as
‘current’, ‘next’ and ‘pending’ describe their original checkpoint.
Use [the documentation entry point](../README.md), [active sprint](../bookie-0.2-sprint.md)
and [the ADR index](../decisions/README.md) for current instructions. Type/value rules
are owned by ADR 0007; connection/session and persistence rules by ADRs 0008/0009.
Read a relevant heading only; this ledger is not mandatory agent startup context.
Append new case evidence with its own date, outcome and source SHA; do not
rewrite an earlier result as proof for a later source tree.

---

# Value preservation tests

Evidence availability checked October 3: some dated `target/quality` links below are unavailable in this checkout. They remain historical references, not current passes. See [the evidence consistency review](architecture-consistency-review-2026-10-03.md#evidence-audit) and its inventory for exact paths; retrieve exact-SHA artifacts or rerun before using missing raw proof for acceptance.


B3 uses a shared boundary corpus at `testdata/value-contract.json`. Tests must
compare the submitted value with the returned value, not just check that a query
succeeded. A NULL, an empty value, an unsupported value and a failed conversion
are different outcomes.

## Run

```bash
./scripts/test-value-contracts.sh --gtk --duckdb
./scripts/test-value-contracts.sh --gtk --duckdb --unit-only
```

The first command covers all eight drivers plus grid, filter, CSV import, named parameter, JSON
export and MCP conversion paths. Docker is required for the six server engines;
SQLite and DuckDB run locally. GTK development libraries are required for the
grid parser. Without `--gtk` or `--duckdb`, the report explicitly records those
exclusions. `--unit-only` keeps the same compilation configuration and runs only
the parser and consumer suites.

The runner compiles once, reads Cargo's test artifact records, and executes each
selected binary. A missing suite, zero matching tests, compilation error, test
failure or five-minute fixture timeout makes the command fail. Every selected suite gets a log and the combined
report is under `target/quality/*-values/report.json`. Failures in one engine do
not prevent the other compiled suites from running.
Integration tests are selected by the `value_contract` name prefix; new driver
value-contract tests must use that prefix or they will run in the full crate
suite but be excluded from this focused layer.

## CSV regression audit, 2026-09-29

The [regression audit](regression-audit-2026-09-29.md) reproduced two missing
consumer cases. Formula-safe negative decimal imports rounded values beyond
Decimal's exact scale, and binary CSV exports used a `\x` prefix the importer
did not accept. The shared parsers now refuse excess decimal precision and
accept that binary prefix. Ordinary hex and SQL-style prefixes remain supported.

The core binary contract exports and imports NULL, empty bytes and all 256 byte
values with each of the four delimiters. A real SQLite contract then builds the
import plan, executes policy-guarded batches and checks native blob/null storage,
exact bytes and the terminal audit count. Decimal units test both raw and
formula-safe inputs beyond the exact scale, alongside existing valid negative
and trailing-zero cases. These are separate from deliberate unsupported native
types and installed grid acceptance.

PostgreSQL/MySQL fixture scenarios extracted to `tests/support/value_contracts.rs`
remain part of their `integration` target. Their module prefixes change displayed
test names; the `value_contract` selection still includes them.

## Full drivers layer, 2026-09-30

After integrating the remote Linux updates, the strict `drivers` layer passed
all six server drivers, PostgreSQL socket, SSH agent authentication and OpenSSH
sessions: 200 tests, zero failures. Evidence:
`20260930T001431188722Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T001431188722Z-layers/report.json`)
and its detailed `drivers-1.log` (raw report unavailable in this checkout: `../target/quality/20260930T001431188722Z-layers/drivers-1.log`).

The first integrated rerun caught a fixture mistake: `.990` legacy `datetime`
lands on an exact every-third 1/300-second tick and is correctly decodable. The
regression now uses `.997` and `.003`, which occupy inexact ticks; it compares
their decoder results with SQL Server's native text, requires SQL export refusal,
and separately round-trips supported temporal columns. The focused Docker test
and the full integrated drivers layer passed.

The integrated strict shared-values runner also passed all 135 selected tests
across GTK, DuckDB, all eight drivers and MCP, with no missing suites:
`20260930T002923239431Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T002923239431Z-values/report.json`).

The latest full driver-layer run, at clean source SHA
`f88159dcb23dd74a960c638a6af42b608a1b4345`, passed 220 tests across the six
server drivers, local PostgreSQL socket, SSH-agent authentication and OpenSSH
sessions, with no failures or ignored tests in executed suites. It explicitly
ran the connection-loss and mid-stream/partial-result contracts for each
remote driver, plus PostgreSQL/MySQL pool recovery and the other drivers'
restart/reconnect paths. Evidence:
`20260930T232244336622Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T232244336622Z-layers/report.json`)
and `drivers-1.log` (raw report unavailable in this checkout: `../target/quality/20260930T232244336622Z-layers/drivers-1.log`).
The layer took 984 seconds, reflecting the Docker-backed end-to-end coverage.

## B3 mutation survivor re-audit, 2026-10-01

I reran two old survivor groups against the current source and test set. The
ClickHouse `clickhouse_datetime64_fits_precision` scope caught all 16 viable
mutations; the former `precision > 9` to `precision >= 9` survivor is now
caught by the exact scale-9 boundary assertion. The core CSV `column_kind`
scope caught 13 of 14 mutations; one was unviable, with no misses or timeouts.
This supersedes older CSV classifier reports whose tests predated the current
type-name matrix.

The JSON exporter scope caught 6 of 7 mutations. Its sole survivor deletes the
explicit `Value::Null` match arm, but that is behaviorally equivalent: the
fallback `value_to_text(Value::Null)` returns `None`, which `value_to_json`
also maps to JSON null. Existing exporter contracts separately assert SQL NULL
as JSON null and text `"null"` as JSON string. This is classified as an
equivalent mutant, not a missed behavior assertion. The focused contract
`value_contract_json_keeps_null_and_booleans_distinct_from_text` passed with
both SQL NULL and text `"null"`. The full strict GTK+DuckDB value runner also
passed all 165 selected tests across 11 suites on the updated working tree:
`20260930T235608800228Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T235608800228Z-values/report.json`).
The quick layer passed after this change:
`20261001T000036771872Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T000036771872Z-layers/report.json`).
Reports:
`clickhouse precision` (raw report unavailable in this checkout: `../target/quality/20261001-clickhouse-datetime64-precision-mutants/mutants.out/outcomes.json`),
`CSV type classifier` (raw report unavailable in this checkout: `../target/quality/20261001-csv-column-kind-mutants/mutants.out/outcomes.json`),
`JSON exporter` (raw report unavailable in this checkout: `../target/quality/20261001-json-value-to-json-mutants-final/mutants.out/outcomes.json`).

## MySQL wide DECIMAL CSV import, 2026-10-01

A failing-first core test reproduced that a valid `DECIMAL(65,30)` CSV value
was rejected as `NotANumber`, although MySQL results preserve values outside
Rust `Decimal` as exact text. Typed import now uses the destination's declared
precision and scale to permit a plain numeric text fallback only when that
value fits the declared type and Rust `Decimal` cannot represent it. Invalid
numeric tokens, malformed type metadata, values beyond the destination's
precision/scale, and high-precision values for unspecified `decimal` metadata
remain errors. A valid `DECIMAL(30,30)` with no integer digits remains accepted.
The metadata parser allows MySQL's `UNSIGNED` and `ZEROFILL` modifiers but
rejects unknown and repeated suffixes; this prevents malformed column metadata
from enabling the text fallback.

The MySQL 8 Docker contract covers a 65-digit integer and a negative
`DECIMAL(65,30)` with formula-safe CSV output. It compares exact JSON strings,
imports CSV using destination catalog metadata, writes the values through
bound parameters and SQL literals, then compares `HEX(CAST(value AS CHAR))`
with the source for both rows. Focused core tests and the live contract passed.
The initial scoped mutation run caught all 30 generated mutations, with no
misses, timeouts, or unviable cases. A follow-up metadata audit added
`DECIMAL(65,0) UNSIGNED` to the live fixture and malformed suffix cases to core
tests; all 489 core tests and the MySQL live contract passed. The latest scoped
run caught all 36 generated mutations, with no misses, timeouts, or unviable
cases:
`20261001-wide-decimal-metadata-mutants-full-core` (raw report unavailable in this checkout: `../target/quality/20261001-wide-decimal-metadata-mutants-full-core/mutants.out/outcomes.json`).
The strict GTK+DuckDB values layer passed 168
selected tests across 11 suites:
`20261001T002624272378Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T002624272378Z-values/report.json`).
After the metadata-suffix change, it passed again with 168 selected tests across
all 11 suites and no missing suites:
`20261001T011112385634Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T011112385634Z-values/report.json`).
The quick layer also passed:
`20261001T003205886474Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T003205886474Z-layers/report.json`).
After the suffix-validation change, the quick layer passed again, including
formatting, Clippy, sandbox tests and the standalone Redis cancellation target:
`20261001T011619474080Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T011619474080Z-layers/report.json`).
The earlier 30-mutant report is
`20261001-wide-decimal-csv-mutants-final3` (raw report unavailable in this checkout: `../target/quality/20261001-wide-decimal-csv-mutants-final3/mutants.out/outcomes.json`).

## MySQL PAD_CHAR_TO_FULL_LENGTH fixed-width text, 2026-10-01

A live MySQL contract now runs with `PAD_CHAR_TO_FULL_LENGTH` enabled and
checks that a `CHAR(5)` value returns all five characters, including trailing
spaces. It verifies the native `CHAR_LENGTH` and `HEX` values, CSV export and
typed CSV import, then repeats the write through both bound parameters and SQL
literal insertion. Each destination is compared with the source using native
length and byte oracles. The focused Docker contract and MySQL integration
Clippy check passed. The strict GTK+DuckDB value layer passed 169 selected tests
across all 11 suites, including eight MySQL scenarios and this contract:
`20261001T013200347651Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T013200347651Z-values/report.json`).

```sh
rtk cargo test --locked -p tablepro-driver-mysql --test integration value_contract_mysql_pad_char_mode_keeps_fixed_width_text_through_csv_and_writes -- --ignored --test-threads=1
```

```sh
rtk cargo test --locked -p tablepro-core --lib value_contract_wide_decimal_csv_cells_remain_exact_text_when_decimal_cannot_hold_them
rtk cargo test --locked -p tablepro-driver-mysql --test integration value_contract_wide_decimal_csv_bound_and_literal_round_trips_preserve_all_digits -- --ignored --exact --test-threads=1
```

## SQL Server datetimeoffset CSV import, 2026-10-01

A failing-first extension to the live `datetimeoffset(7)` contract reproduced a
CSV import failure: SQL Server's space-separated timestamp with a numeric UTC
offset was rejected as `NotATimestamp`. Parsing it as the shared UTC-normalized
`TimestampTz` value would also discard the original stored offset. The CSV type
classifier now keeps `datetimeoffset` as exact text. A core test pins all seven
fractional digits and the `+05:30` offset.

The Docker-backed driver contract now checks exact JSON output, CSV export and
production CSV import, then inserts the imported values using native bound
parameters. An independent SQL Server query compares both the instant and
`DATEPART(TZOFFSET, ...)` with the source for five offsets, including calendar
extremes. The focused test passed after first reproducing the failure. Scoped
mutation testing of `temporal_kind` caught 4 of 5 generated mutations; one was
unviable, with no missed or timed-out mutants. The strict runner passed 165
selected tests across all 11 suites:
`20260930T230409137178Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T230409137178Z-values/report.json`).
The quick layer also passed after the documentation update:
`20260930T231132409175Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T231132409175Z-layers/report.json`).

```sh
rtk cargo test -p tablepro-core --lib import::cell::tests::value_contract_mssql_datetimeoffset_csv_cells_preserve_the_original_offset_and_scale -- --exact
rtk cargo test -p tablepro-driver-mssql --test integration value_contract_datetimeoffset_keeps_its_offset_through_results_parameters_and_exports -- --include-ignored --exact --test-threads=1
```

## DuckDB zero-row result metadata, 2026-09-28

A local DuckDB query selects a `HUGEINT` and `VARCHAR` under `WHERE false`.
The result has no rows and is not truncated, but keeps the ordered aliases and
Arrow-backed metadata (`Decimal128(38, 0)` and `Utf8`). A second query checks
DuckDB's native `typeof` values are `HUGEINT` and `VARCHAR`, so driver metadata
is recorded separately from engine type names.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration query_with_zero_rows_preserves_column_metadata_and_completeness -- --exact
```

The focused local DuckDB contract passed.

## PostgreSQL zero-row result metadata and ordered delivery, 2026-09-29

A PostgreSQL Docker contract first reproduced a result-delivery defect: a
zero-row `SELECT` returned no column metadata because the driver populated
names and types only from the first `PgRow`. The driver now prepares an empty
result to recover its statement metadata, using the original parameter types
for bound queries. The regression checks ordered names and native types for
plain and parameterized empty results, then checks duplicate aliases, values,
and row order for a populated result.

```sh
rtk cargo test -p tablepro-driver-postgres --test integration value_contract_result_delivery_keeps_zero_row_metadata_duplicate_names_and_order -- --ignored --exact --test-threads=1
```

The focused Docker contract passed against PostgreSQL; the empty-result
metadata defect is fixed. The strict combined runner later passed all 120
selected contracts on the source tree including this regression and the added
numeric parser cases; see
`20260929T161811049211Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260929T161811049211Z-values/report.json`).

## PostgreSQL server termination and pool recovery, 2026-09-29

A failing-first Docker contract terminated an active PostgreSQL backend and
showed SQLSTATE `57P01` was surfaced as an ordinary query error. The driver now
classifies PostgreSQL server termination states `57P01` through `57P04` as
`Disconnected`; the normal query-cancel state `57014` remains a query error. The
contract checks that the terminated operation fails visibly and that the same
pooled connection can complete a fresh `SELECT 1` afterward. A second Docker test
stops and restarts PostgreSQL on a stable mapped host port; the existing pool must
report the outage as `Disconnected` and then complete a new `SELECT 1`. A unit contract
distinguishes the termination states from query cancellation and constraint
errors. A second failing-first unit case showed generic SQLx socket EOF/reset
errors also surfaced as `Internal`; those now map to `Disconnected`, while
connection refusal and TLS errors retain their distinct classifications.

```sh
rtk cargo test -p tablepro-driver-postgres --lib server_termination_states_are_disconnections_but_query_cancel_is_not
rtk cargo test -p tablepro-driver-postgres --lib unexpected_io_eof_is_disconnected_and_connection_refusal_stays_distinct
rtk cargo test -p tablepro-driver-postgres --test integration server_terminated_query_reports_disconnection_and_pool_recovers -- --include-ignored --exact --test-threads=1
rtk cargo test -p tablepro-driver-postgres --test integration disconnection::a_restarted_postgres_server_restores_the_existing_pool -- --ignored --exact --test-threads=1
```

All 35 PostgreSQL unit tests and the focused Docker test passed. The SQLSTATE
mutation run caught both generated changes; the socket/error-classification run
caught 7 of 8 mutants, with one unviable. The clean strict value runner passed
131 selected tests across all 11 suites at source
`12e795cec416fca9da92ed1c95ae6bd9b77e754e`, with no missing suites. Evidence:
`target/quality/20260929-pg-disconnect-mutants-home/mutants.out/outcomes.json`,
`target/quality/20260929-pg-io-disconnect-mutants-final/mutants.out/outcomes.json`,
and `target/quality/20260929T212538645091Z-values/report.json` (`dirty: false`).

## MySQL server termination and pool recovery, 2026-09-29

A failing-first MySQL Docker contract killed the connection serving an active
`SLEEP` query. The server closed the socket with unexpected EOF, which the SQLx
mapper previously surfaced as `Internal`. The driver now maps SQLx I/O failures
to `Disconnected`, while keeping connection refusal and TLS errors distinct.
The integration contract requires the killed query to fail promptly, then checks
the pool completes a new `SELECT 1`. A second Docker test stops and restarts MySQL
on a stable mapped host port; the existing pool must return `Disconnected` during
the outage and then complete a new `SELECT 1`. Unit tests separately preserve
`ConnectionRefused` and unexpected EOF classifications.

```sh
rtk cargo test -p tablepro-driver-mysql --lib
rtk cargo test -p tablepro-driver-mysql --test integration server_terminated_query_reports_disconnection_and_pool_recovers -- --include-ignored --exact --test-threads=1
rtk cargo test -p tablepro-driver-mysql --test integration a_restarted_mysql_server_restores_the_existing_pool -- --ignored --exact --test-threads=1
```

The focused integration test and all 12 MySQL library tests passed. The first
scoped mutation pass found the connection-refusal branch lacked its own
assertion; after adding it, all three viable mutations were caught and one was
unviable. Evidence:
`target/quality/20260929-mysql-disconnect-mutants-final/mutants.out/outcomes.json`.
The clean strict runner passed 131 selected tests across 11 suites at source
`064b4947d07d4fddbc2a210c0d658f62cef59805`; no suites were missing:
`target/quality/20260929T211702925065Z-values/report.json` (`dirty: false`).

### MySQL mid-stream disconnect completeness, 2026-09-30

A Docker regression streams 100 rows with a short delay per row, waits until
MySQL reports the query active, then kills its connection after row production
has begun. The driver must return `Disconnected` for the whole query, not a
partial result, and the pool must complete a fresh `SELECT 1`. The focused
integration test passed locally: 1 test passed. Mid-stream or mid-page
whole-operation failure cases now exist for all six remote drivers: PostgreSQL,
MySQL, SQL Server, MongoDB, Redis and ClickHouse. The runner enables these
ignored fixtures through the `drivers` layer. This is coverage inventory; the
current commit's hosted driver-layer result is tracked separately.

```sh
rtk cargo test --locked -p tablepro-driver-mysql --test integration backend_loss_during_row_stream_fails_the_whole_query_as_disconnected -- --ignored --exact --test-threads=1
```

### MySQL TLS error classification, 2026-09-30

The full TLS fixture exposed a second MySQL I/O classification case: SQLx wraps
rustls `InvalidCertificate(NotValidForName)` in an `InvalidData` I/O error, so
the mapper returned `Disconnected` for a certificate hostname mismatch. The
mapper now walks the I/O source chain and detects TLS failures before its
generic disconnection fallback. The regression asserts a wrapped TLS cause
stays `Tls`; ordinary EOF remains `Disconnected`, and connection refusal stays
`ConnectionRefused`.

```sh
rtk cargo test --locked -p tablepro-driver-mysql --lib
rtk python3 scripts/run-test-layer.py tls
```

All 13 MySQL library tests passed. The complete TLS layer passed all 35
fixture tests, including the previously failing MySQL identity check. The
scoped mutation run caught 5 of 6 generated mutations; one was unviable:
`target/quality/20260930-mysql-tls-map-mutants/mutants.out/outcomes.json`.
Layer evidence:
`target/quality/20260929T225302522187Z-layers/report.json`.

## MongoDB transport disconnect classification, 2026-09-30

A failing-first mapper test showed that MongoDB reset, EOF and broken-pipe
transport errors were surfaced as generic query errors. The mapper now returns
`Disconnected` for connection-aborted, reset, broken-pipe, unexpected-EOF and
not-connected I/O failures. Connection refusal remains distinct; TLS detection
still runs first, and unrelated I/O such as permission denial remains a query
error. A local unused-port test checks server-selection failures remain
`ConnectionRefused`; a Docker-backed wrong-password test verifies
`AuthFailed`. The Docker-backed server-loss contract connects and performs an
operation, stops MongoDB, and requires the next operation to return
`Disconnected`. It pins the container to a stable host port, restarts the same
container, and verifies the existing client can list collections again. The
stable port ensures recovery exercises the same endpoint.

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --lib
rtk cargo test --locked -p tablepro-driver-mongodb --test integration an_unavailable_mongodb_server_is_classified_as_connection_refused -- --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mongodb --test integration wrong_mongodb_credentials_are_classified_as_auth_failed -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mongodb --test integration a_lost_mongodb_server_is_reported_as_disconnected -- --ignored --exact --test-threads=1
```

All 34 MongoDB library tests, the local refused-endpoint test, the Docker
authentication test and the server-loss classification test passed. The initial
same-client recovery attempt failed with a random mapped port. After reserving
and mapping a fixed host port, the focused contract passed in 6.84 seconds. The
server-loss test first failed because an established operation surfaced
`ConnectionRefused`; operations now map server-selection failures and transport
refusal to `Disconnected`, while connect-time refusal stays `ConnectionRefused`. The first
nine-mutant mapper run caught 6, missed
the untested authentication and server-selection branches, and found one
unviable mutation. Both missed branches now have regressions; separate targeted
mutation runs caught the authentication and server-selection mutants. Reports:
`target/quality/20260930-mongodb-disconnect-mutants/mutants.out/outcomes.json`,
`target/quality/20260930-mongodb-auth-map-mutant/mutants.out/outcomes.json`, and
`target/quality/20260930-mongodb-selection-map-mutant/mutants.out/outcomes.json`.

### MongoDB cancellation preserves client usability, 2026-10-01

A MongoDB 7 `failCommand` fixture blocks one `listCollections` command. The
test polls `currentOp` and confirms the command is active before cancelling,
then requires `OperationOutcomeUnknown(Cancelled)` and successfully lists
collections again through the same client. This verifies cancellation stays
distinct from disconnect and does not strand later operations.

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --test integration a_cancelled_mongodb_read_leaves_the_client_usable -- --ignored --exact --test-threads=1
```

The focused Docker contract passed: 1 test, 26 filtered, in 0.92 seconds.

## Redis disconnect classification, 2026-09-30

A Docker-backed regression first connected and completed `PING`, stopped the
Redis server, then required a second command to fail as `Disconnected`. Before
the fix it returned a generic query error (`broken pipe`). Redis error mapping
now treats dropped connections, timeouts and I/O errors during established
operations as `Disconnected`; TLS and authentication checks still run first.
Connection refusal, reset and broken pipe during connection setup remain
`ConnectionRefused`, distinct from an established connection loss. The Docker
contract now restarts Redis and requires a fresh connection to complete `PING`.

```sh
rtk cargo test --locked -p tablepro-driver-redis --lib
rtk cargo test --locked -p tablepro-driver-redis --test integration a_lost_redis_server_is_reported_as_disconnected -- --ignored --exact --test-threads=1
```

All 37 Redis library tests and the Docker server-loss/restart test passed. The first
copy-based mutation attempt stopped during its clean baseline build because the
temporary filesystem quota was exhausted; it ran no mutants. An in-place scoped
run found two survivors caused by redundant checks: in redis 1.7, timeout and
dropped-connection predicates are both I/O errors, and `is_connection_dropped`
is already implied by `ErrorKind::Io`. The mapper now uses that single I/O-kind
contract. The final run caught 8 of 9 mutants; one was unviable, with no missed
or timed-out mutants. Reports:
`target/quality/20260930-redis-disconnect-mutants/mutants.out/outcomes.json`,
`target/quality/20260930-redis-disconnect-mutants-inplace/mutants.out/outcomes.json`,
and `target/quality/20260930-redis-disconnect-mutants-final/mutants.out/outcomes.json`.
The setup-time reset/broken-pipe regression failed before the mapper fix. A
targeted mutation run of the mapper caught 6 of 7 mutants; one was unviable,
with no missed or timed-out mutants:
`target/quality/20260930-redis-startup-disconnect-mutants/mutants.out/outcomes.json`.

## PostgreSQL mid-stream disconnect completeness, 2026-09-30

A Docker-backed regression starts a 100-row query with a short delay per row,
waits until PostgreSQL reports its backend active, then terminates that backend
after row production has begun. The driver must return `Disconnected` for the
whole query rather than present any partial rows as a complete result. The same
pool must then complete `SELECT 1` successfully. This complements the existing
query-start termination and full-server restart cases. The focused integration
case passed locally: 1 test passed. The broader cross-driver mid-stream contract
remains open.

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration disconnection::backend_loss_during_row_stream_fails_the_whole_query_as_disconnected -- --ignored --exact --test-threads=1
```

## ClickHouse disconnect classification, 2026-09-30

A Docker-backed regression completed `SELECT 1`, stopped ClickHouse, then
required a second query to return `Disconnected`. The test initially received
`ConnectionRefused`: the shared mapper classified network refusal as a
connection-setup error even for established queries. Error mapping now keeps
`ConnectionRefused` during connect and reports network loss during later
operations as `Disconnected`; TLS detection remains ahead of both paths.

```sh
rtk cargo test --locked -p tablepro-driver-clickhouse --lib
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration a_lost_clickhouse_server_is_reported_as_disconnected -- --ignored --exact --test-threads=1
```

All 39 ClickHouse library tests and the Docker server-loss/restart test passed. The
first scoped mutation run found an uncovered distinction between setup-time
`connect error` and operation-time refusal. New mapper regressions cover both
forms, including refusal during an established operation. The rerun caught 4
of 5 mutants; one was unviable, with no missed or timed-out mutants. Reports:
`target/quality/20260930-clickhouse-disconnect-mutants/mutants.out/outcomes.json`
and `target/quality/20260930-clickhouse-disconnect-mutants-final/mutants.out/outcomes.json`.

### ClickHouse row-stream interruption completeness, 2026-09-30

Docker contracts stop ClickHouse while `sleepEachRow` produces a chunked result.
A forced stop must return `Disconnected`, never a partial `QueryResult`, and a
fresh driver connection must work after restart. Graceful shutdown follows a
different server path: ClickHouse 24.8 appends `QUERY_WAS_CANCELLED` as a
single-cell JSON row after already emitted data. Before the fix, the driver
returned those prior rows plus the exception text as a successful result. The
decoder now recognizes the server exception shape and returns a query error,
while the same message remains recognizable by the controlled-cancellation
path. A unit contract distinguishes that exception payload from ordinary text.
Both focused Docker cases and all 40 ClickHouse library tests passed. The
decoder's scoped mutation run caught all 11 generated mutants, with no missed,
timed-out or unviable mutants:
`target/quality/20260930-clickhouse-exception-row-mutants-final/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-driver-clickhouse --lib tests::clickhouse_terminal_exception_row_is_an_error_not_partial_success -- --exact
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration disconnection::server_loss_during_row_stream_fails_the_whole_query_as_disconnected -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration disconnection::graceful_server_stop_during_row_stream_returns_an_error_not_partial_rows -- --ignored --exact --test-threads=1
```

## SQL Server disconnect delivery, 2026-09-30

A Docker-backed test completes `SELECT 1`, stops the SQL Server container, then
requires the next query on the established connection to return `Disconnected`.
This confirms the driver does not surface server loss as a generic query error.
The test then restarts the same container, reconnects through the driver and
requires a fresh `SELECT 1` to succeed.

```sh
rtk cargo test --locked -p tablepro-driver-mssql --test integration a_lost_sql_server_is_reported_as_disconnected -- --ignored --exact --test-threads=1
```

The focused SQL Server server-loss/restart test passed.

A second Docker contract interrupts a multi-result stream after its first row
set has arrived, while the server is in `WAITFOR`. SQL Server returns TDS error
596 (session is in the kill state) when the stream is drained. The mapper
previously surfaced this terminal session failure as an ordinary query error;
it now reports `Disconnected`. The test requires the query to fail as a whole,
then restarts SQL Server and verifies a fresh `SELECT 1`. A unit contract keeps
596 distinct from login failure and ordinary SQL errors. All 32 library tests
and the complete SQL Server integration suite passed (31 tests, including the
Docker cases; 147 seconds). The mapper mutation run caught both viable
match-arm mutations; one whole-function mutant was unviable, with no missed or
timed-out mutants:
`target/quality/20260930-mssql-terminal-session-map-mutants/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-driver-mssql --test integration server_loss_during_multi_result_stream_rejects_the_whole_query -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mssql --lib terminal_session_kill_is_disconnected_but_sql_errors_are_preserved
```

## Connect refusal versus established disconnect, 2026-09-30

Native-driver checks against unused local TCP ports cover PostgreSQL, MySQL,
SQL Server, ClickHouse, Redis and MongoDB. The PostgreSQL and MySQL checks first
failed: SQLx retries refused connections while creating a pool and eventually
returns `PoolTimedOut`, which the shared operation mapper classified as
`Disconnected`. Their setup paths now map that pool-startup failure to
`ConnectionRefused`, while `PoolTimedOut` from an established operation remains
`Disconnected`. Unit contracts assert both contexts, and the full driver
connect path verifies the observable result. MongoDB's pre-existing refused-
endpoint test supplies its native-driver check.

The focused checks passed for all five shared-helper callers; MongoDB's existing
unused-port test remains in the driver's integration suite. The initial failing
PostgreSQL and MySQL runs reproduced the incorrect `Disconnected` classification.
Scoped mutation runs caught both generated changes to the setup-time timeout
predicate in PostgreSQL and MySQL. An earlier PostgreSQL broad test run missed
the `true` mutant because no `PoolClosed` case distinguished a startup timeout;
the added unit case now catches it. The final PostgreSQL and MySQL predicate
runs each caught 2 of 2 mutants. The first function-wide mutation was unviable
because `DriverError` has no `Default`; the predicate-scoped reruns are the
retained mutation evidence:
`target/quality/20260930-pg-connect-refusal-predicate-mutants-final/mutants.out/outcomes.json`
and `target/quality/20260930-mysql-connect-refusal-predicate-final/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-driver-postgres --lib a_pool_startup_timeout_is_not_mapped_as_an_established_disconnect
rtk cargo test --locked -p tablepro-driver-mysql --lib a_pool_startup_timeout_is_not_mapped_as_an_established_disconnect
rtk cargo test --locked -p tablepro-driver-postgres --test integration an_unavailable_postgres_server_is_classified_as_connection_refused -- --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mysql --test integration an_unavailable_mysql_server_is_classified_as_connection_refused -- --exact --test-threads=1
```

## Restart recovery across remote drivers, 2026-09-30

The PostgreSQL and MySQL pool tests stop and restart the server container while
keeping its mapped host port stable, then verify the existing pool reconnects
after reporting `Disconnected`. The MongoDB, Redis, ClickHouse and SQL Server
server-loss tests restart the same Docker container after checking
`Disconnected`, refresh the mapped host port, and establish a fresh connection
through the driver. A bounded shared
test helper retries only connection refusal, disconnection, timeouts and the
Redis startup broken-pipe case; each test still requires a protocol-level
operation to succeed. This proves explicit reconnect after restart; it does not
claim transparent recovery of the old connection handle.

The full Docker-backed driver layer passed 207 driver, MCP, PostgreSQL socket
and SSH tests after the restart and setup-refusal additions, with zero failures
in 864.5 seconds. The quick layer also passed after the SQLx mapping correction.
Reports:
`20260930T021134930354Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T021134930354Z-layers/report.json`)
and `20260930T020929420585Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T020929420585Z-layers/report.json`).

The integrated layer passed again on exact commit
`8680cc0d38a917218163eaf3ce9fe4b9c190a6da`: 930.5 seconds, exit code 0, clean
worktree. All six server-driver suites, the real-MongoDB MCP browse round trip,
Extended JSON BSON re-import, PostgreSQL socket tests and SSH fixtures passed;
no executed suite failed or ignored a test. The report and complete test log are
`20260930T122803925695Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T122803925695Z-layers/report.json`)
and `drivers-1.log` (raw report unavailable in this checkout: `../target/quality/20260930T122803925695Z-layers/drivers-1.log`).
`scripts/ci-local.sh integration` activates the ignored MCP fixture explicitly;
the direct rerun also passed:

```sh
rtk cargo test --locked -p tablepro-mcp --test mongodb_extended_json -- --include-ignored --exact mongodb_extended_json_survives_the_mcp_query_tool_round_trip --test-threads=1
```

The real-server MCP test now independently reads the seeded document through
MongoDB's native driver before dispatch. It checks Decimal128, BSON DateTime,
user-defined binary subtype `80`, Int64 above 2^53, explicit NULL and Unicode,
then requires the MCP browse result to preserve the matching Extended JSON
markers and values. This distinguishes an exact MCP response from a fixture
that happened to contain only JSON lookalikes. The focused Docker test passed.

On September 30, the full Docker-backed `drivers` layer was rerun at source SHA
`8ed0f66ed54b1411feaac5d7a8e49abc6999fb18`. It ran 219 tests with zero failures
or ignored tests in the executed suites in 939.7 seconds. The six server-driver
disconnect and mid-stream/page-loss regressions passed, as did the pool/fresh
connection recovery paths, MCP, PostgreSQL socket and SSH checks. See
`20260930T110146955489Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T110146955489Z-layers/report.json`)
for the per-step report.

After splitting the nested MongoDB test into its own support module, the strict
shared value-contract runner passed with GTK and DuckDB enabled against base SHA
`736a73f8434a57fd33dbe9d6212956e29351b168`. It executed 144 tests across all 11
expected suites, reported no missing suites, and finished in 201.7 seconds.
Compilation found 746 fresh artifacts and rebuilt one package. The quick layer
then passed in 92.0 seconds, including file-size and function-size guards. See
`20260930T114622059959Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T114622059959Z-layers/report.json`),
`20260930T114622117990Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T114622117990Z-values/report.json`)
and `20260930T114425279874Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T114425279874Z-layers/report.json`).

Before the restart additions, an earlier source snapshot passed 200 selected
driver, socket and SSH tests and the strict shared-values layer passed 135 tests
with GTK and DuckDB enabled and no missing suites. That historical evidence is
retained here; the current 207-test driver and quick reports are above:
`20260930T010431493880Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T010431493880Z-layers/report.json`),
`20260930T011850614654Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T011850614654Z-layers/report.json`),
`20260930T011850675572Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T011850675572Z-values/report.json`),
and `20260930T012435775212Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T012435775212Z-layers/report.json`).

## DuckDB duplicate result column names, 2026-09-28

A local `UNION ALL` result returns two columns with the same alias and two rows.
The contract asserts that both names remain `duplicate`, values stay in their
original columns and row order, and the result is not marked truncated. This
preserves the engine result shape without inventing unique aliases.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration query_preserves_duplicate_column_names_and_row_order -- --exact
```

The focused local DuckDB contract passed.

## DuckDB row-cap completeness, 2026-09-28

The local DuckDB result limit is checked at both boundaries. A query returning
exactly `MAX_QUERY_ROWS` preserves the first and last ordered values and reports
`truncated = false`; a query with one additional row still returns the capped
count and reports `truncated = true`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration query_marks_only_results_over_the_row_cap_as_truncated -- --exact
```

The focused local DuckDB contract passed.

## SQL Server multi-result draining, 2026-09-28

The SQL Server batch API represents one `QueryResult`, so the contract records
the supported behavior: return columns and rows from the first result set,
drain later sets, and report a server error raised after the first set instead
of silently returning success. A subsequent query verifies the connection
remains usable after the late error.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql --test integration an_error_raised_after_the_first_result_set_is_reported -- --include-ignored --exact --test-threads=1
```

The focused SQL Server Docker contract passed.

## MongoDB page metadata and grid editability, 2026-09-30

MongoDB's `fetch_rows` returns page columns formed from the first-50 sample
and the current page; conflicting observed BSON kinds are labeled `mixed`.
The browse UI previously retained only the earlier `ColumnsLoaded` columns,
leaving grid factories and schema-dependent filters with stale metadata. It now
uses page columns for the active result, keeps the initial metadata for drivers
whose page results omit columns, and rebuilds factories when any `ColumnInfo`
changes, even when the column count is unchanged. This ensures mixed columns
remain read-only and late fields use their observed metadata. Schema discovery
for documents outside the sample and returned page is still not exhaustive.

The regression tests cover the Mongo page-schema handoff, preservation of
non-Mongo behavior and same-width type-change invalidation. A follow-up now
feeds the effective page schema into the actual cell editability predicate: a
text cell stays editable under the sampled string schema, but becomes read-only
when the current page reports `mixed`. The latest full app library run passed
411 tests (12 ignored). A scoped in-place mutation run against the page-schema
handoff caught all 3 viable mutations; 3 whole-function replacements were
unviable, with no survivors or timeouts.

```sh
rtk cargo test --locked -p tablepro-app --lib browse_tab::tests -- --nocapture
rtk cargo test --locked -p tablepro-app --lib mongodb_page_schema_updates_late_fields_and_mixed_types_before_grid_editing -- --test-threads=1
rtk cargo test --locked -p tablepro-app --lib
rtk cargo mutants --dir linux --in-place --package tablepro-app --file crates/app/src/ui/browse_tab/mod.rs --re 'columns_for_browse_page' --test-tool cargo --timeout 30 --build-timeout 180 --output linux/target/quality/20260930-mongodb-page-editability-mutants-inplace -- --lib mongodb_page_schema_updates_late_fields_and_mixed_types_before_grid_editing -- --test-threads=1
rtk python3 scripts/run-test-layer.py widgets
```

### MySQL malformed routine delimiter fails closed, 2026-09-30

An unterminated quote inside a `DELIMITER $$` routine must not expose the
trailing query as executable script. The editor contract requires a planner
diagnostic, execution planning refusal, no parameter extraction from the
malformed tail, source preservation through formatting and an `Unparseable`
write classification denied by the agent policy. The regression passed; no
planner or policy defect was found.

```sh
rtk cargo test --locked -p tablepro-app --lib malformed_mysql_delimited_routine_blocks_the_whole_script -- --test-threads=1
```

## MongoDB BSON kind matrix audit, 2026-09-30

The type matrix still listed unnamed top-level BSON kinds as open. The
exhaustive driver type-classification match and Extended JSON fallback were
compared with native grid fixtures: Timestamp, regex, JavaScript,
JavaScript-with-scope, Symbol, DbPointer, Undefined, MinKey and MaxKey all have
native keyed-edit assertions; binary subtypes and BSONColumn have dedicated
native checks, and scalar/container variants have driver value contracts. The
whole MongoDB integration suite passed all 26 tests, including ignored Docker
fixtures. The remaining MongoDB schema gap is collection-wide discovery beyond
the first-50 sample and current result page.

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --test integration -- --include-ignored --test-threads=1
```

## MongoDB nested-document grid edit, 2026-09-30

A Docker-backed app contract now takes a displayed nested document through the
MongoDB app parser, keyed update builder and driver, then reads it with a separate
native MongoDB client. The edited cell contains an Int64 above JavaScript's safe
integer boundary, a scale-preserving Decimal128, and an ObjectId inside the
nested document. The contract also checks the target `_id`, an untouched sibling
field and a second row's full contents. This joins the app/driver paths that had
previously only been covered separately by parser and BSON codec tests.

```sh
rtk cargo test --locked -p tablepro-app --lib value_contract_mongodb_nested_document_edit_preserves_extended_bson_and_row_identity -- --ignored --test-threads=1
```

The focused Docker test passed: 1 passed, 0 failed.

## Current corpus

The [type-contract strategy](../type-contract-strategy.md) defines boundary families,
proof requirements and remaining driver targets. This status was reconciled through
`linux` commit `b2bc42729b145b91f0f75f8d40b3fa0a69e7a31d` on 2026-09-29. The
strict combined run passed with GTK and DuckDB enabled, including the app's
optional DuckDB parser/edit contract: all 11 selected crates passed 119
contracts, no suites were missing, 741 artifacts were fresh, and four packages
were rebuilt. The report records `dirty: false` and the exact commit:
`target/quality/20260929T063203554829Z-values/report.json`. This does not
establish complete native-type support or replace installed-app acceptance.

| Path | Assertions |
| --- | --- |
| PostgreSQL, MySQL, SQLite, SQL Server, ClickHouse, DuckDB | Bound parameters and generated SQL preserve signed integer limits, values around 2^53, small/large floats, text and NULL |
| Six SQL drivers, mixed named bindings | Repeated names, signed integer limits, empty text versus NULL, SQL-like Unicode payloads and placeholder-looking text retain type, position and exact content |
| Fixed-decimal SQL engines | Positive and negative decimals retain their value through binding and generated SQL; SQLite has no fixed-decimal storage contract |
| Redis | Integer command replies and quoted text arguments retain their values; a missing key differs from empty text; RESP3 hash maps preserve binary field values, nested structures use tagged JSON, and BigNumber digits remain exact |
| MongoDB | JSON commands preserve integer, float, text and NULL values through BSON and result decoding |
| Grid, filter, CSV and named parameter parsers | Integer overflow and decimal rounding are refused; representable boundaries survive parsing |
| Float input parsers | Numeric overflow to infinity and nonzero underflow to zero are refused |
| XLSX | Integers beyond 15 digits, exact decimals, and finite floats Excel may round or underflow are text cells; XML verifies values and cell types, while safe finite floats remain numeric |
| JSON and MCP | Non-finite values and negative zero remain distinct from SQL NULL and positive zero |

### Redis RESP3 nested values and binary replies

Top-level RESP arrays continue to produce one result row per item, and top-level
maps remain key/value rows. Nested arrays become JSON arrays, while nested maps
and sets carry `$redisMap` and `$redisSet` markers so their shape is explicit.
Invalid UTF-8 bulk strings inside nested values use a lowercase hex
`$redisBytes` marker; direct bulk values remain `Value::Bytes`. BigNumber uses
exact decimal text as a scalar and a `$redisBigNumber` marker when nested. A
separate boundary test builds a map one item beyond `MAX_QUERY_ROWS` and checks
that only the capped rows are returned with `truncated: true`.

The focused unit contract first failed against the previous decoder, which
returned Rust debug strings such as `array([binary-data(...)])`. The map cap
contract also caught a false-complete result before its fix. Unit tests also
check `$redisAttribute` and `$redisPush` markers; these prove conversion, not
live subscription behavior. All 34 Redis unit tests pass. A Redis 7.4 Docker
contract switches to RESP3, reads an HGETALL map with text and invalid UTF-8
values, then reads an XREAD stream response with nested values and binary data.
All 3 Redis Docker integration tests pass.

```sh
rtk cargo test --locked -p tablepro-driver-redis --lib redis_nested_replies_keep_structure_and_binary_bytes
rtk cargo test --locked -p tablepro-driver-redis --test integration value_contract_resp3_hash_map_preserves_binary_fields_and_values -- --include-ignored --exact --test-threads=1
```

The XREAD stream map/array response has real Redis 7.4 coverage. Attribute
wire framing is checked through a local RESP3 TCP fixture in addition to unit
conversion tests. Asynchronous push delivery is covered by explicit refusal for
streaming commands; other server push-frame delivery remains open.

### Redis Pub/Sub and MONITOR stream refusal, 2026-09-29

A Redis 7.4 Docker regression first demonstrated that `SUBSCRIBE` returned a
one-shot `$redisPush` subscription acknowledgement, although the request /
response API cannot deliver later message pushes. A second failing-first case
showed that `MONITOR` returns `OK` before switching into its continuous event
stream. `CLIENT TRACKING ON BCAST` likewise returned `OK` while enabling
invalidation pushes. The driver now refuses
`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`, and their three unsubscribe commands
as `Unsupported` before sending them. It also refuses `MONITOR` and
`CLIENT TRACKING ON` with any trailing flags. The live contract exercises each
streaming command on one connection, checks the refusal explanation, then
confirms `PING`, `CLIENT TRACKING OFF`, `PUBLISH`, `PUBSUB CHANNELS` and
`CLIENT LIST` still work. This prevents a one-shot acknowledgement from
implying that an ongoing stream is being received while preserving adjacent
one-shot commands. It does not add a streaming API or establish live delivery
for other asynchronous pushes or attribute frames. The first scoped mutation
pass caught 2, left 2 missed and found one unviable whole-query replacement.
After adding live negative assertions, iteration caught both survivors:
cumulatively 4 caught, 1 unviable, no survivors or timeouts. Evidence:
`target/quality/20260929-redis-async-push-mutants/mutants.out.old/outcomes.json`
and `target/quality/20260929-redis-async-push-mutants/mutants.out/outcomes.json`.
The clean combined runner passed after the tracking-push addition at
`af46f18461e98a5ec83833e9c18556211b7f1b56`: 125 selected contracts across 11
suites, with no missing suites. Evidence:
`target/quality/20260929T191639404194Z-values/report.json` (`dirty: false`).

The command matrix now also covers `CLIENT TRACKING ON OPTIN NOLOOP`,
`CLIENT TRACKING ON REDIRECT 1`, and mixed-case `CLIENT TRACKING ON BCAST
NOLOOP`. The strict combined runner selected the ignored Redis Docker test and
passed all 127 contracts across 11 suites. Evidence:
`target/quality/20260929T195657915401Z-values/report.json` (`dirty: true`; the
test and ledger edits were present in the working tree during the run).

After the RESP3 wire contract was committed, the strict combined runner passed
all 128 contracts across 11 suites with no missing suites at
`887a1bd61060e5c604e9d4e52cb821de4dcf2202` (`dirty: false`). Both the stream
refusal contract and the attribute-wire contract appear as passed Redis tests.
Evidence: `target/quality/20260929T200632950370Z-values/report.json`.

```sh
rtk cargo test -p tablepro-driver-redis --test integration value_contract_redis_stream_commands_are_refused_without_consuming_the_connection -- --include-ignored --exact --test-threads=1
```

### Redis RESP3 attribute wire framing

An unignored local TCP fixture switches the real redis client connection to
RESP3 with `HELLO 3`, then sends a wire-level attribute frame attached to
`PONG`. The driver returns the payload and TTL metadata in its tagged JSON
representation, verifying framing through the socket decoder and query
conversion. This is protocol-client evidence; the separate Docker fixture
continues to verify responses from Redis 7.4 itself.

```sh
rtk cargo test -p tablepro-driver-redis --test integration value_contract_resp3_attribute_wire_frame_survives_the_request_response_connection -- --exact --test-threads=1
```

## CSV negative-zero export/import, 2026-09-28

A focused core contract exports IEEE-754 negative zero as CSV, reads the result
back through the delimited-file reader and typed `DOUBLE PRECISION` cell parser,
then compares the imported float's bit pattern with the submitted value. The
independent `to_bits()` oracle distinguishes negative zero from positive zero.
The test passed; no production mismatch was found.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_negative_zero_bits
```

## CSV signed integer boundary export/import

The typed `BIGINT` CSV round trip covers `i64::MIN`, `i64::MAX`, and
`9007199254740993` (one above the exact-integer limit of binary64). It checks
both the emitted decimal digits and the exact imported `Value::Int` values.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_signed_integer_boundaries
```

The focused core test passed.

## CSV decimal scale export/import

A typed `DECIMAL(10,4)` CSV round trip preserves `12.3000` in the emitted
token and in the imported `Decimal` scale. The assertions compare the text
representation because numeric equality alone would treat `12.30` and
`12.3000` as equivalent.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_decimal_trailing_zeroes
```

The focused core test passed.

## JSON negative-zero consumer contract

The JSON exporter writes finite negative zero as the numeric token `-0.0`.
Parsing the exported document recovers the original IEEE-754 negative-zero
bits, while positive zero remains positive and SQL NULL remains JSON null.
This is a JSON writer and parser contract; it does not establish all JSON
number bit patterns.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_json_keeps_negative_zero_distinct_from_positive_zero_and_null
```

The focused core test passed.

A second typed CSV contract carries `NaN`, positive infinity, negative infinity
and NULL through default CSV export and `DOUBLE PRECISION` import. It checks the
exact emitted tokens, the imported NaN/infinity classifications and NULL variant.
The regression passed; no production mismatch was found.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_keeps_nonfinite_floats_distinct_from_null
```

The default CSV export and typed `DOUBLE PRECISION` import also preserve the
smallest positive subnormal (`f64::from_bits(1)`) exactly. The importer result is
compared by IEEE-754 bits; the focused regression passes with no production
mismatch. The largest finite `f64` also survives the default CSV export and
typed import with its exact bit pattern.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_smallest_subnormal_bits
```

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_largest_finite_float_bits
```

### Seeded finite float consumer parity

A deterministic xorshift corpus now combines six explicit edge values,
65,536 raw finite IEEE-754 bit samples, and 20,470 sign/exponent/mantissa
boundary values (86,012 entries total). Every value round-trips through default
CSV export, typed `DOUBLE PRECISION` import, and JSON export/parse with exact
`to_bits()` comparisons. Exponent-all-ones patterns are rejected, so generated
samples remain finite; the fixed seed makes failures repeatable without another
test dependency. The unignored core unit test passes. This broad corpus does
not exhaust every finite `f64` encoding. See the
[finite-float consumer evidence](../evidence/finite-float-consumer-results-2026-10-04/manifest.json).

```sh
rtk cargo test --locked -p tablepro-core --lib value_contract_csv_and_json_round_trip_seeded_finite_float_bits
```

Spreadsheet-application import and other finite `f64` bit patterns remain open.

A typed `TIMESTAMP WITH TIME ZONE` CSV contract starts with a timestamp at
`+05:30` and nine fractional digits. Default export normalizes it to the exact
UTC token, and typed import reproduces the identical UTC instant. This closes
one nanosecond/timezone consumer cell; broader cross-format temporal parity
remains open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib value_contract_csv_round_trip_preserves_timestamptz_nanoseconds
```

ClickHouse long-value reads are checked with a server-generated value. Oversized
inline SQL is required to return its explicit query-size error; the fixture does
not raise that server limit or accept a truncated success.

## PostgreSQL script consumer agreement, 2026-09-28

A local policy integration contract uses CRLF line endings and issue-shaped
comments before, between, inside and after two statements. The comments and a
quoted literal contain semicolons and placeholder-shaped text. The planner must
return exactly the SELECT then UPDATE; parameter extraction must retain only
`shown`, then `name` and `id`; formatting must preserve comment text and leave
the same executable statements in order. Policy classification must still see
SELECT then UPDATE, including the UPDATE target and WHERE clause. This verifies
consumer agreement for this PostgreSQL boundary without a live database; it
does not close the other dialects or delimiter edge cases.

Focused result:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-policy --test administrative_dialects postgres_script_consumers_agree_across_crlf_comments_and_formatting -- --exact
```

The test passed. No production defect was exposed.

The editor also converts GTK's character offset to a UTF-8 byte offset before
asking the planner for a statement. A focused app regression places `東京` in
the first statement and positions the cursor at the start of the second; it
asserts the mapped byte offset and that the editor selects `SELECT 2`. The
conversion was already present inline, so this closes an evidence gap rather
than correcting a behavior mismatch.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib gtk_character_offset_after_multibyte_text_selects_the_following_statement -- --test-threads=1
```

The test passed.

A second app regression passes `SELECT :safe; SELECT 'unfinished :tail` through
the planner, execution splitter, parameter extractor, formatter and policy. The
planner reports an unterminated quote; the app rejects the entire script rather
than returning its valid prefix. Parameter extraction converts only `:safe`
and leaves the malformed suffix intact, the formatter retains that suffix, and
policy classifies the whole input as unparseable and write-capable. This closes
the malformed-tail contract for PostgreSQL only.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib malformed_tail_is_not_accepted_as_a_valid_script_prefix -- --test-threads=1
```

The test passed. No production defect was exposed.

## SQL Server GO consumer agreement, 2026-09-28

An app regression sends three statements through a SQL Server script with two
`GO` batch separators. Placeholder-shaped text and semicolons in each `GO`
comment must not become parameters. The planner and app splitter retain three
statements and `ContinueNextBatch`; the formatter preserves both separators and
comments; named-parameter extraction returns only `read`, `name`, `id` and
`last`; policy classification keeps SELECT/UPDATE/SELECT order and the UPDATE
WHERE fact. The contract uses the shared lexer and formatter without a live
SQL Server. A word-character delimiter adjacent to the routine END keyword now has a planner/editor/parser regression; other delimiter forms remain open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib mssql_go_batches_keep_consumer_order_and_ignore_delimiter_comments -- --test-threads=1
```

The test passed. No production defect was exposed.

## SQL Server repeated GO count refusal, 2026-09-28

The app contract feeds `GO 2` through the SQL Server script consumers. The plan
retains the repeat count, but execution planning refuses to run it instead of
silently running the batch once. Formatting keeps the directive and its comment;
parameter extraction returns only the SQL parameter, and policy classifies the
full repeated script as unparseable and write-capable. This proves safe refusal,
not repeated-batch execution support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib mssql_go_repetition_is_preserved_and_refused_by_script_execution
```

The test passed; no production defect was found.

## SQL Server `datetime2(7)` 100-nanosecond result precision

The temporal fixture checks its `datetime2(7)` result directly:
`2024-01-02 03:04:05.1234567` decodes to a `NaiveDateTime` with
`123456700` nanoseconds, matching the independent server text from
`CONVERT(varchar(27), precise, 126)`. Its full source row also contains legacy
`datetime`, so SQL literal export must refuse that row rather than bypass the
decoder's `Undecodable` marker. A separate projection round-trips supported
`smalldatetime`, `datetime2(7)`, `time(7)` and `date` columns and compares native
server values. This verifies the seventh fractional digit through decoding and
SQL export; it does not claim coverage for all SQL Server temporal edge cases.

```sh
rtk cargo test --locked -p tablepro-driver-mssql --test integration inexact_legacy_datetime_refuses_sql_export_but_supported_temporals_round_trip -- --include-ignored --exact --test-threads=1
```

The old integration assertion failed on `UnrepresentableValue { column: "legacy" }`,
which was the correct safety behavior. The regression now compares both
undecodable legacy cells with exact SQL Server text, requires export refusal for
the legacy column, and round-trips the remaining supported temporal projection.
The focused Docker test passed; no production mismatch was found.

### SQL Server `smalldatetime` rounding threshold

A focused server test checks values at the `smalldatetime` second-rounding
boundary. `03:04:29.998` decodes and renders as `03:04:00`; `03:04:29.999`
rounds to `03:05:00`. Each decoded `DateTime` is checked beside SQL Server's
independent style-126 text value. The Docker test passed with no production
mismatch; broader legacy temporal boundaries remain open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql --test integration value_contract_smalldatetime_rounding_matches_server_text -- --include-ignored --exact --test-threads=1
```

### SQL Server legacy `datetime` tick boundaries

A SQL Server Docker contract checks legacy `datetime`
rounding around its 1/300-second tick boundaries (`.001`, `.002`, `.004`,
`.005`, `.008`). Tiberius exposes each 1/300-second tick through
`NaiveDateTime`, which truncates some values to integer nanoseconds. Every third
tick is exact in nanoseconds and remains a typed value; other non-NULL legacy
`datetime` values become `Undecodable("datetime")` instead of exposing an
editable approximation. SQL NULL stays `Value::Null`. The fixture checks each
result beside SQL Server's independent rounded text.
`smalldatetime` and `datetime2` continue to use typed values.

```sh
rtk cargo test --locked -p tablepro-driver-mssql --test integration value_contract_legacy_datetime_refuses_ticks_chrono_cannot_represent -- --include-ignored --exact --test-threads=1
```

The focused SQL Server Docker contract passed. A codec unit contract also checks
both nullable legacy type identifiers and confirms `datetime2` remains exact.
The first combined value run caught that `DATETIMN` metadata is shared by
`datetime` and `smalldatetime`; refusal now keys off Tiberius's distinct
`ColumnData::DateTime` versus `SmallDateTime` variants. The failed run is retained
at `target/quality/20260929T062250469254Z-values/report.json`; the focused
smalldatetime regression passes after the correction.
The final codec predicate mutation run caught both polarity changes (2/2),
including treating every nullable temporal payload as inexact; evidence is at
`target/quality/20260929-mssql-legacy-datetime-mutants-precise/mutants.out/outcomes.json`.

#### October 4 exact text fallback follow-up

The earlier refusal was safe but left supported round-trip coverage incomplete.
Inexact 1/300-second ticks now decode to canonical SQL Server style-126 text;
ticks exactly representable in nanoseconds remain typed `DateTime` values.
The focused export contract restores sample values with identical `varbinary(8)`
bytes. A generated native sweep checks all 300 distinct ticks against independent
style-126 text, binds all typed/text values back to a `datetime` column, and
compares each stored 8-byte value. Null and `datetime2` behavior remain covered.

```sh
rtk cargo test -p tablepro-driver-mssql --test integration inexact_legacy_datetime_uses_exact_text_and_supported_temporals_round_trip -- --ignored --exact
rtk cargo test -p tablepro-driver-mssql --test integration value_contract_all_legacy_datetime_ticks_round_trip_through_parameters -- --ignored --exact
rtk cargo test -p tablepro-driver-mssql --test integration value_contract_legacy_datetime_fallback_matches_session_batch_and_native_text -- --ignored --exact
```

All three focused Docker tests passed locally, including parity through the
session batch API. Portable command logs and source fingerprints
are in [the evidence packet](../evidence/mssql-legacy-datetime-ticks-results-2026-10-04/manifest.json).

The app grid follow-up verifies the displayed text fallback and typed
fractional datetime through the app parser and keyed-update builder. It checks
native `varbinary(8)` values and an untouched sibling before/after the no-op
edit. This exposed and fixed the grid display's omission of nonzero fractional
seconds for `Value::DateTime`.

```sh
rtk cargo test -p tablepro-app --lib ui::browse_tab::value_parse::mssql_legacy_datetime_contract::value_contract_mssql_legacy_datetime_text_grid_edit_preserves_wire_value_and_siblings -- --ignored --exact
```

The SQL Server Docker contract passed; see the [app grid evidence](../evidence/mssql-legacy-datetime-grid-edit-results-2026-10-04/manifest.json).

## SQL Server money float-decoding refusal

A Docker regression first reproduced SQL Server `money` as
`Float(123456789012345.67)` even though an independent server-side decimal text
cast returned `123456789012345.6789`. `smallmoney` also travels through the
TDS client's floating-point representation. Non-NULL `ColumnType::Money` returns
`Undecodable("money")`, and `ColumnType::Money4` returns `Undecodable("smallmoney")`.
Nullable `smallmoney` is `ColumnType::Money` because pinned Tiberius maps every
`VarLenType::Money` to `Money`, so that path returns `Undecodable("money")`.
NULL remains NULL. The result's separate decimal text oracles preserve the
server's exact values. This is a safe refusal, not exact `money` editing or
binding support. A second live row sets both native values to SQL NULL and
checks that the result cells stay `Value::Null`, separate from the undecodable
non-NULL row.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql --lib money_columns_refuse_float_decoding_but_preserve_null
rtk cargo test -p tablepro-driver-mssql --test integration value_contract_money_values_are_refused_but_server_nulls_remain_null -- --include-ignored --exact --test-threads=1
```

The focused codec unit test and updated Docker integration test passed. The
strict combined runner also passed all 121 selected contracts on commit
`71813f8d2`; evidence is
`20260929T162725389033Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260929T162725389033Z-values/report.json`).

### SQL Server `sql_variant` metadata refusal

A SQL Server Docker regression first checked the native base type and exact
`CONVERT(varchar(40), value)` text for `bigint` value `9007199254740993`, which
is beyond binary64's exact-integer range. Selecting the `sql_variant` then
reproduced a panic in the pinned Tiberius TDS metadata parser's unimplemented
`SSVariant` branch. The driver caught that dependency panic at the result
boundary and retired the partially consumed stream. The same behavior was
checked for a shared connection and isolated session.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql --test integration sql_variant_result_is_refused_without_panicking_or_reusing_the_connection -- --include-ignored --exact --test-threads=1
```

The focused SQL Server Docker contract passed at that dependency revision.

Follow-up on 2026-10-09: Tiberius 0.13 decodes the tested `bigint` base value,
but a `sql_variant` column can contain different base types and the shared
`Value` does not retain the per-cell type. Results now keep the declared
`sql_variant` column metadata and mark non-NULL cells undecodable; SQL NULL
remains NULL. Fully consumed results leave shared connections and isolated
sessions usable. The panic guard still retires a stream if another base type
triggers Tiberius's known `SSVariant` panic.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql --test integration sql_variant_values_are_undecodable_and_keep_connections_usable -- --ignored --test-threads=1
```

Exact per-cell base-type decoding and editing remain open.

Scoped `cargo-mutants` testing of `variant_guard.rs` first found that a
mutation making the refusal classifier return `true` for every error survived.
Negative assertions for unrelated unsupported operations and server query errors
were added. The final run caught 7 mutations, had 1 unviable mutation, and had
no survivors or timeouts. The initial survivor and final report are retained at
`target/quality/20260929-mssql-variant-guard-mutants/` and
`target/quality/20260929-mssql-variant-guard-mutants-final/`.

```sh
rtk cargo mutants --package tablepro-driver-mssql --file crates/drivers/mssql/src/variant_guard.rs --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260929-mssql-variant-guard-mutants-final -- --lib variant_guard::tests
```

## MySQL DELIMITER consumer agreement, 2026-09-28

An app regression uses `DELIMITER $$` around a stored procedure, resets the
delimiter to `;`, then runs a parameterized SELECT. The planner and editor
splitter return the procedure followed by the SELECT and omit client directives
from executable SQL. Formatting retains both directives. Parameter extraction
ignores placeholder-shaped text in directive comments and in the procedure's
quoted literal, retaining only `after` from the SELECT. The policy parser marks
the procedure statement unparseable and write-capable, then classifies the
following query as SELECT; agent policy denies the unparseable procedure. This
verifies client-side delimiter handling, not that stored-procedure definitions
are executable through BookiE. Human handling of unparseable SQL remains
policy-config dependent.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib mysql_delimiter_directives_agree_across_script_consumers -- --test-threads=1
```

The test passed. No production defect was exposed.

A second app regression uses the alternate `//` delimiter around a routine with
both semicolons and placeholder-shaped text inside a quoted string. Planning,
editor splitting, formatting and parameter extraction preserve the routine and
trailing SELECT, while only `after` is extracted as a parameter. This covers
`$$` and `//`; other delimiter forms remain open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib mysql_slash_delimiter_is_preserved_across_planner_editor_and_parameters -- --test-threads=1
```

The focused app regression passed.

Text cases include empty strings, numeric-looking strings, Unicode, apostrophes,
quotes, backslashes, line breaks and text beyond 256 KiB. Float assertions in the
SQL harness compare bit patterns. Existing driver tests still cover binary
exports, typed row identity, cancellation, metadata and other engine behavior.
The new suite supplements those tests.

This is a growing contract, not proof of every database type. PostgreSQL's other
unconstrained numeric edit boundaries and special numerics, JSON and other unsupported array element
types, array grid write-back beyond the verified built-in `integer[]` case,
finite calendars beyond the shared range, and interval consumer parity still need
focused cases. ClickHouse Int128/UInt128
now have local parser and real-server exact-text result, binding and SQL export/import contracts at signed and unsigned boundaries, plus Int128 and UInt128 grid-edit contracts.
Installed GTK/package SQLite grid acceptance, spreadsheet floating-point edges and
remaining transport/persistence adapters also need focused cases. Add a reproducer
before changing a decoder or parser. Never make
a failing exact-value case pass by converting both sides to floats or by treating
an unsupported result as NULL.

## Build reuse

Cargo already caches build artifacts in `target`. Preserve that directory and
keep the toolchain, feature selection, profile and compiler flags consistent.
Changes to a shared crate correctly rebuild its consumers. Different package
selections can produce different dependency features and build-dependency hashes;
that can rerun DuckDB's C++ build even when its own feature list is unchanged.
See [Cargo build cache](https://doc.rust-lang.org/cargo/reference/build-cache.html)
and [feature resolution](https://doc.rust-lang.org/cargo/reference/features.html#feature-resolver-version-2).

Use the same flags for repeated value-suite runs. The report records compile
seconds, fresh artifacts and rebuilt packages, so cache reuse is measurable.
Changing the test filter with `--unit-only` does not change the compile graph.
The local integration runner also selects the six server driver packages in one
Cargo invocation, including MongoDB. The PostgreSQL socket fixture preserves
`RUSTUP_HOME` while isolating application state, avoiding a fresh toolchain
download into its temporary home.

A secondary compiler cache such as [sccache](https://github.com/mozilla/sccache)
can help when switching build configurations or rebuilding native code. It is
not installed or enabled by this change. It cannot avoid relinking changed code
or replace tests, and Rust incremental compilation affects what it can cache.
No existing artifacts are deleted and no global Cargo or desktop settings change.

## Measured checkpoint: 2026-09-26

The complete `--gtk --duckdb` suite passed twice after the fixes. Evidence:

- `target/quality/20260926T182536049588Z-values/report.json`: all 11 selected
  suites passed; 33.393 seconds compiling changed Rust code.
- `target/quality/20260926T182710143702Z-values/report.json`: unchanged rerun;
  all suites passed, 0.924 seconds in the build step, 745 fresh artifacts and
  zero rebuilt packages. Database startup and test execution still take time.

- `target/quality/20260926T184410518775Z-integration/report.json`: 93 server
  integration tests and two PostgreSQL socket tests passed.
- `target/quality/20260926T184128878545Z-full/report.json`: full local gate
  passed; Debian package validation skipped because `dpkg-deb` is unavailable.
- `target/quality/20260926T184028346457Z-values/report.json`: final parser
  refinement and runner timeout handling; all 11 suites passed.

After preserving `RUSTUP_HOME`, the socket fixture passed again with build
steps of 0.50 and 0.33 seconds and no toolchain download.

These runs used the dirty working tree based on `9b7a996ca`; these are local
implementation results, not qualification of a frozen release candidate.

## XLSX integer and decimal checkpoint

The regression first reproduced `i64::MIN` becoming `-9223372036854776000`
and a wide decimal becoming `100000000000000000000`. Exports now store
integers beyond 15 digits and every exact decimal as text. Smaller integers
remain numeric. Decimal scale survives; arithmetic on these text cells requires
explicit conversion, which can lose precision in the spreadsheet application.
The test opens the generated XLSX ZIP and checks cell references against their
exact shared strings, not just successful file creation. The shared value runner
picks up both workbook regressions automatically.

Excel documents its [15-digit precision limit](https://support.microsoft.com/en-us/excel/format-numbers-as-text).
Spreadsheet import and spreadsheet-application re-import contracts remain open.

### XLSX float precision and Excel-safe cell types, 2026-10-02

A failing-first workbook contract showed that finite `f64` values were always
written as numeric cells, including negative zero, subnormals and values with
more than Excel's 15 significant decimal digits. Excel documents both its
15-digit precision and numeric magnitude limits in its
[specifications](https://support.microsoft.com/en-us/excel/excel-specifications-and-limits).
The writer now keeps finite floats numeric only when their shortest decimal has
at most 15 significant digits and the magnitude is within Excel's supported
numeric range. Risky values use exact text cells, preserving the sign of
negative zero and the decimal needed to reconstruct the original float. This
trades spreadsheet arithmetic for exact value retention on those cells, matching
the existing text policy for wide integers and exact decimals.

Workbook XML tests cover both numeric range boundaries, ordinary safe numbers,
negative zero, the smallest subnormal, the adjacent value above 1.0, a 17-digit
float, and `f64::MAX`. The exact-text cases were numeric cells before the fix;
they now emit as shared-string cells, while safe values remain numeric cells.
BookiE has no XLSX importer and LibreOffice is unavailable in the local
verification environment, so application-specific formula/re-import behavior
remains unverified.

```sh
rtk cargo test --locked -p tablepro-core --lib export::xlsx::tests::value_contract_workbook
```

The exact selectors and source SHA are retained with the current review evidence.

### XLSX nested Extended JSON consumer check, 2026-09-27

The workbook regression writes a nested value containing Decimal128, binary
subtype and millisecond-date Extended JSON markers. It inspects the generated
XLSX shared-string cell and confirms the markers remain in one exact text cell.
The focused regression and all 436 core library tests passed. At this
checkpoint, it verified the shared XLSX writer boundary. A later MongoDB 7
integration regression now exercises actual driver query results through XLSX;
see [MongoDB nested BSON and native boundary checkpoint](#mongodb-nested-bson-and-native-boundary-checkpoint).

Validation: 415 core tests, core/workspace Clippy, size guards and `cargo deny
check` passed. The full local gate passed at
`target/quality/20260926T195741317332Z-full/report.json` on the working tree
based on `49981d123`; Debian validation was skipped because `dpkg-deb` is
unavailable. The XLSX regression failed before the fix.

## PostgreSQL NUMERIC decoding checkpoint

The real-server regression first returned an undecodable marker for a 40-digit
NUMERIC. The decoder now reads the base-10000 wire groups directly and retains
the server scale. Exactly representable values remain Decimal; wider values,
longer fractions, NaN and infinities remain text. NULL stays separate.
Direct, bound and session queries are compared with PostgreSQL numeric-to-text
output, including positive/negative values, 1e1000 and 1e-1000. Unit cases
exercise maximum wire weight and scale, malformed lengths, invalid groups/signs,
and values whose nonzero digits would otherwise be truncated by scale.

This closes the scalar decode gap. Arbitrary-precision editing, numeric arrays
and every downstream consumer still need their own acceptance. The encoding
follows PostgreSQL [numeric_send](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/adt/numeric.c).

Validation: all 45 PostgreSQL unit/integration tests passed. The full local gate
passed at `target/quality/20260926T202553866194Z-full/report.json` on the
working tree based on `28df4581c`; Debian package validation was skipped because
`dpkg-deb` is unavailable. No new dependencies were added.
The all-eight-driver suite also passed at
`target/quality/20260926T202754372916Z-values/report.json`: all 11 selected
suites, including both PostgreSQL cases and eight core cases.

## PostgreSQL wide NUMERIC grid edit

The keyed-update builder binds a text-backed PostgreSQL `NUMERIC` edit through
`text` to the fixed `pg_catalog.numeric` type. Its unit contract covers a
`NUMERIC(80,40)` value with 40 integer digits and 40 fractional digits, beyond the
shared Decimal representation. Type metadata is matched against a numeric-only
grammar and never copied into SQL; ordinary text columns keep their existing
placeholder. The real-server contract compares the saved value with PostgreSQL's
own `numeric::text` output and passed against the Docker PostgreSQL fixture.

The focused core tests passed:

```sh
cargo test --locked -p tablepro-core --lib postgres_numeric -- --test-threads=1
cargo test --locked -p tablepro-core --lib postgres_wide_numeric -- --test-threads=1
```

The mapped change-contract gate also passed its four keyed-update regressions at
`target/quality/20260928T121821319834Z-change-contracts/report.json`.

The server test is discoverable as
`wide_numeric_contract::value_contract_wide_numeric_grid_edit_preserves_exact_value`.
The first run exposed two fixture mismatches: the temporary table was invisible to
pooled connections, and browse primary-key metadata was absent. After fixing those,
the server equality assertion passed. The `NUMERIC(1000,1000)` boundary contract
also passed against PostgreSQL, comparing the saved value to the server's
`numeric::text` output after a keyed grid update:

```sh
cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration wide_numeric_contract::value_contract_max_precision_numeric_grid_edit_preserves_exact_value -- --include-ignored --exact --test-threads=1
```

An app-parser regression then reproduced that the same `NUMERIC(80,40)` and
`NUMERIC(1000,1000)` inputs failed as `Invalid decimal` before reaching the grid
update builder. The PostgreSQL-only parser now retains a grammar-checked numeric
literal as exact text when `rust_decimal` cannot represent it; representable
values still use `Value::Decimal`. Its `NUMERIC(80,40)` case passes the parsed
value through the keyed-update builder and verifies the static
`$1::text::pg_catalog.numeric` cast. It rejects malformed input, and MySQL's
wide-numeric parser behavior is unchanged. Local app tests pass. PostgreSQL's
Docker composition test now uses the real app parser output, keyed-update
builder and PostgreSQL driver against both `NUMERIC(80,40)` and unconstrained
`numeric`, then compares each saved value to the server's independent
`numeric::text` output. The unconstrained case uses a 40-digit integer and
40-digit fraction, outside `rust_decimal` precision. The same app test sends an
unconstrained numeric at PostgreSQL's maximum fractional scale of 16,383 digits
and at its maximum integer width of 131,072 digits through the parser and keyed-
update builder. The server confirms exact `numeric::text` values, the fractional
scale, and the integer text length. Both unconstrained numeric width boundaries
are covered; other text-backed PostgreSQL types remain open. See
[PostgreSQL numeric type limits](https://www.postgresql.org/docs/16/datatype-numeric.html).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib postgres_numeric_parser_outputs_round_trip_through_server -- --include-ignored --test-threads=1
```

The test passed against the PostgreSQL 16 Docker fixture.

A separate PostgreSQL 16 contract covers a custom domain over `numeric`. The
40-digit integer/20-digit fraction remains exact in the domain result and the
server's `numeric::text` oracle; SQL-literal re-import and an explicitly typed
text binding also return the same value. This establishes the numeric-domain
cell, not broad domain, enum, composite or range support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration wide_numeric_contract::value_contract_numeric_domain_preserves_wide_value_across_consumers -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL Docker test passed.

A second domain contract uses PostgreSQL's `uuid` base type. The direct domain
result remains `Value::Uuid`; an independent `uuid::text` value and
`pg_typeof` name confirm the native value/type. SQL-literal re-import and a
typed UUID parameter also produce the exact text. This closes one non-numeric
domain consumer case only.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_uuid_domain_preserves_uuid_across_consumers -- --include-ignored --exact --test-threads=1
```

The PostgreSQL 16 Docker contract passed.

### PostgreSQL JSONB domain and JSON null

A custom domain over `jsonb` preserves JSON null as `Value::Json(Null)` while a
SQL NULL of the same domain remains `Value::Null`. PostgreSQL independently
confirms the domain type, `jsonb_typeof`, and `IS NULL` results. SQL-literal
re-import and a typed JSON binding retain JSON null; a typed SQL NULL binding
remains SQL NULL. This closes one JSON-domain value/consumer cell without
claiming broad nonnumeric-domain coverage.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_jsonb_domain_keeps_json_null_distinct_from_sql_null -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed.
The full PostgreSQL Docker integration suite passed (56 tests) on the current
worktree; this is local evidence, not hosted CI evidence.

### PostgreSQL `bit varying` exact text consumers

A PostgreSQL 16 contract exposed that the driver returned `Undecodable("VARBIT")`
for a valid 80-bit value even though PostgreSQL's text, bit count and equality
oracles agreed. The binary decoder now validates the declared bit count, packed
byte length and unused low padding bits, then renders every bit in order so
leading zeroes remain exact. The result, SQL-literal re-import and typed text
binding all preserve the same 80-bit string.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --lib bit_strings_keep_leading_zeroes_and_reject_malformed_wire_values
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_varbit_preserves_leading_zero_bits_across_consumers -- --include-ignored --exact --test-threads=1
```

Both the decoder unit test and PostgreSQL 16 Docker contract passed.

### PostgreSQL `macaddr` exact text consumers

A live PostgreSQL probe showed that the six-byte `macaddr` binary value was
returned as `Undecodable("MACADDR")` even though its server text and
`macaddr_send` wire bytes were exact. The driver now renders the six octets as
PostgreSQL's lowercase colon-separated text and rejects malformed byte counts.
The result, SQL-literal re-import and typed text binding preserve
`08:00:2b:01:02:03`; this contract covers `macaddr`, not `macaddr8`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --lib macaddr_requires_six_bytes_and_uses_postgres_lowercase_text
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_macaddr_preserves_exact_text_across_consumers -- --include-ignored --exact --test-threads=1
```

Both focused checks passed against the unit decoder and PostgreSQL 16 Docker
fixture.

### PostgreSQL `macaddr8` exact text consumers

The first PostgreSQL 16 Docker run confirmed the result consumer returned
`Undecodable("MACADDR8")` while `pg_typeof`, `::text`, and `macaddr8_send`
independently agreed on the eight-byte EUI-64 value. The binary decoder now
renders exactly eight octets in PostgreSQL's lowercase colon-separated form
and rejects malformed wire lengths. Result decoding, SQL-literal re-import,
and typed text binding preserve `08:00:2b:ff:fe:01:02:03`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --lib macaddr8_requires_eight_bytes_and_uses_postgres_lowercase_text
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_macaddr8_preserves_eui64_text_across_consumers -- --include-ignored --exact --test-threads=1
```

The unit decoder and PostgreSQL 16 Docker contract passed. The baseline Docker
run reproduced the undecodable result while PostgreSQL's native type, exact
text, and eight-byte wire oracle agreed.

### PostgreSQL `inet` and `cidr` consumer parity

A focused PostgreSQL 16 contract distinguishes an IPv6 `inet` host address with
a `/64` mask from the corresponding canonical `cidr` network. Independent
`host`, `network`, `masklen`, `pg_typeof`, and `::text` results confirm the
address-versus-network semantics. Both values survive SQL-literal re-import
and typed text binding with their exact prefixes.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_inet_and_cidr_preserve_ipv6_prefix_semantics -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed.

### PostgreSQL maximum `pg_lsn` consumer parity

The PostgreSQL 16 contract covers `FFFFFFFF/FFFFFFFF`, the maximum unsigned
64-bit LSN. Server `pg_lsn::text`, `pg_lsn_send` bytes, type metadata and
equality confirm the exact value; direct result decoding, SQL-literal
re-import and typed text binding all retain the same uppercase segment text.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_pg_lsn_maximum_preserves_text_and_wire_identity -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed.

### PostgreSQL `int4range` explicit refusal

The PostgreSQL 16 contract checks a native `1,5)` range against the server's
exact `int4range::text`, lower/upper bounds, and endpoint-inclusion functions.
The driver returns `Undecodable`; SQL-literal rendering and parameter binding
refuse that value rather than flattening range semantics into text.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_int4range_is_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL Docker contract passed. This is an explicit refusal
boundary, not support for PostgreSQL range values.

### PostgreSQL `int4multirange` metadata boundary

PostgreSQL 16 server-side projections independently confirm the native type,
exact `{[1,3),[5,8)}` text, `[1,8)` range hull, and two component ranges. A
direct multirange projection currently fails before BookiE receives a value:
SQLx metadata resolution rejects PostgreSQL's `typtype` code `m`. The contract
records this upstream decoding blocker; it does not claim a BookiE `Undecodable`
value or SQL-literal/binding refusal because no `Value` is produced. A separate
SQL boolean confirms SQL NULL remains null without projecting the multirange.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_int4multirange_metadata_resolution_failure_is_explicit -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed with that metadata error.

The companion contract now covers the five remaining built-in multirange types:
`int8multirange`, `nummultirange`, `datemultirange`, `tsmultirange` and
`tstzmultirange`. PostgreSQL independently returns each type name, canonical
text, merged hull and component count. SQLx rejects direct projection of every
type with the same unsupported `typtype` metadata error, and a separate
`IS NULL` check confirms SQL NULL remains observable. Together with the
`int4multirange` contract, the suite now records the limit for all six built-in
multirange types without claiming support or replacing native server oracles
with client formatting.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_remaining_builtin_multiranges_fail_explicitly_with_native_oracles -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed. Direct support remains open
until SQLx can resolve PostgreSQL multirange metadata safely.

### PostgreSQL composite explicit refusal

A PostgreSQL 16 fixture defines `(id bigint, label text)` and returns a value
containing `9007199254740993` and `東京`. PostgreSQL's `row_to_json`, type name,
and individual field expressions provide exact independent oracles. The
composite result is `Undecodable`; SQL-literal rendering and parameter binding
refuse it instead of flattening its structure.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_composite_result_is_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL Docker contract passed. This does not add composite
support.

### PostgreSQL temporal range explicit refusal

The PostgreSQL 16 contract returns a `tstzrange` spanning two fractional-second
instants supplied at `+02`, with UTC fixed for independent text oracles. The
driver marks the range `Undecodable`; server `tstzrange::text`, lower/upper
`timestamptz::text`, type name, and endpoint-inclusion functions confirm the
stored bounds and `[)` semantics. SQL-literal rendering and parameter binding
refuse the result. This adds one temporal range refusal boundary and does not
add PostgreSQL range support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_tstzrange_is_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL Docker contract passed.

### PostgreSQL built-in range family refusal

A PostgreSQL 16 Docker contract checks `daterange`, `numrange`, `tsrange` and
`int8range`. Each native result is `Undecodable`, while independent server
oracles verify the type name, canonical `::text`, lower and upper values, and
endpoint inclusivity. SQL-literal rendering and typed parameter binding refuse
each result, so these values are not flattened into lossy text. The existing
`int4range` and `tstzrange` tests retain their more detailed boundary coverage.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contracts::value_contract_builtin_range_families_are_refused_without_losing_native_text -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed.

### PostgreSQL scalar enum label text projection

A PostgreSQL 16 contract defines labels `NULL`, `東京`, and `o'brien`. For
each label, PostgreSQL's `pg_typeof` confirms the source expression remains the
custom enum while `enum::text` returns the exact label; SQL-literal re-import
and an explicitly typed text parameter also preserve it. SQL NULL is checked
separately from the literal label `NULL`. At this October 2 checkpoint,
directly returning the enum-typed column failed during SQLx type metadata
resolution (`enum_labels`:
unexpected NULL), so direct decoding remained open at that checkpoint. The
October 3 support that resolved it is recorded below.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contracts::value_contract_scalar_enum_labels_preserve_exact_text -- --include-ignored --exact --test-threads=1
```

The strict value layer passed this contract against PostgreSQL 16. It now
exercises direct projection as well: with the pinned SQLx version, the query
returns `enum_labels: unexpected NULL` during metadata resolution. The test
asserts that exact failure boundary; if SQLx begins decoding the type, it instead
requires all three labels and SQL NULL to arrive exactly. This is a tested
metadata boundary, not exact typed support or a BookiE `Undecodable` value.
The clean GTK+DuckDB value runner passed 185 selected tests across 11 suites
with no missing suites on `e704831`; its
[layer report (local ignored report, not portable: `../target/quality/20261002T001913901283Z-layers/report.json`)
and suite details (local ignored report, not portable: `../target/quality/20261002T001913960449Z-values/report.json`)
record this regression.

### PostgreSQL custom enum array metadata boundary

At this October 2 checkpoint, a PostgreSQL 16 fixture defined enum labels
`NULL`, `東京`, and `o'brien`, then built an array containing all three labels
plus SQL NULL. Server-side scalar projections confirmed the exact native array
type, PostgreSQL array text, and JSON semantics. Selecting the enum array itself
failed during SQLx metadata resolution (`enum_labels`: unexpected NULL); it did
not produce a BookiE `Undecodable` value. This recorded the open decoder/dependency
boundary before the October 3 SQLx parser fix below.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration array_contract::value_contract_custom_enum_array_projection_is_rejected -- --include-ignored --exact --test-threads=1
```

The PostgreSQL 16 contract passed: independent server projections succeeded,
and direct enum-array projection returned the expected metadata error.

### PostgreSQL direct custom-enum result follow-up (October 3)

The current tree adds direct scalar and array decoding for ordinary custom enum
labels. A PostgreSQL 16 test checks `ready`, `paused`, SQL NULL, the native
`pg_typeof` text, and the exact array text `{"ready","paused",NULL}`. The
decoder uses the enum's UTF-8 wire label and quotes each array label so a SQL
NULL element remains distinct. Before the fix, the scalar labels were
`Undecodable`; the retained before-fix output is in
[`before-fix.txt`](../evidence/postgres-enum-results-2026-10-03/before-fix.txt).

### PostgreSQL domain-over-enum array text parameter, 2026-10-04

A domain-over-enum array is also tested through an explicitly cast text
parameter. The input distinguishes the literal label `NULL`, empty text,
Unicode, a comma-containing label and SQL NULL. The decoded array, JSON,
`pg_typeof` and `array_send` bytes match an independently constructed native
array; an invalid element is rejected with SQLSTATE `22P02`. See the
[evidence manifest](../evidence/postgres-domain-enum-array-parameter-results-2026-10-04/manifest.json).

The same typed parameter path now checks a 2×2 array with lower bounds 0 and 3.
The result asserts exact array text, dimensions, JSON shape, outer domain-array
type and each bound while distinguishing the literal `NULL`, empty text,
Unicode and SQL NULL. See the
[bounds evidence](../evidence/postgres-domain-enum-array-bounds-results-2026-10-04/manifest.json).

At this original October 3 decoder checkpoint, the adversarial scalar fixture
whose enum label is literally `NULL` still surfaced SQLx's metadata resolution
error (`enum_labels: unexpected NULL`), and keyed-edit proof remained open.
  The later October 3 support and write follow-up below supersedes that status.
The historical sections above retain their original checkpoint results.

### PostgreSQL enum literal-NULL result support (October 3)

SQLx's PostgreSQL text-array decoder removed element quotes, then treated any
resulting string equal to `NULL` as SQL NULL. The local SQLx 0.9.0 patch now
tracks whether an element was quoted. Its unit regression distinguishes quoted
`"NULL"`, unquoted SQL NULL, lowercase `null`, empty text and ordinary text.
Native Bookie scalar and array projections preserve the enum label `NULL`; a
native `UPDATE ... RETURNING` stores that label and fires its trigger once.
Schema-aware keyed updates and draft inserts also preserve it separately from
SQL NULL. Automatic parameter typing and the remaining enum consumer matrix
remain open under ADR 0007. Current source fingerprints and native results are
in the [enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

A PostgreSQL 16 native regression creates `status_kind` and `items` in two
schemas, then edits only the `enum_shadow_b.items` row. The app's fetched enum
metadata and keyed-update builder select `enum_shadow_b.status_kind` even with
the same type and table names present in `enum_shadow_a`. A role default points
`search_path` at `enum_shadow_a`, confirmed on the fresh pool connection; independent
`pg_typeof` and sibling queries verify the target native type and unchanged
shadow row. Under the same `search_path`, a structured equality filter on
`enum_shadow_b.items` also selects only the target enum value; the native type
and row value remain `enum_shadow_b.status_kind`/`paused`. This closes the
same-named cross-schema keyed-edit/filter combination, while other enum/session
combinations remain open. See the
[shadowed-filter evidence](../evidence/postgres-shadowed-enum-filter-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum structured filters (October 3)

Structured browse filters previously emitted `status = $1` for a custom enum
while binding `$1` as text. A PostgreSQL 16 regression first failed with
SQLSTATE 42883 (`enum = text`). The filter builder now uses fetched,
schema-qualified enum metadata to cast values for equality, inequality, range,
`BETWEEN`, and `IN`/`NOT IN` comparisons. The native fixture checks equality
and inequality for literal label `NULL`, a Unicode `IN` match, enum ordering
through `BETWEEN`, and `IS NULL` independently. Results include native type
oracles; explicit enum `NULL` and SQL NULL remain distinct. The text-pattern
filter path retains its text cast behavior.

The core unit suite passed 502 tests and the PostgreSQL integration suite passed
74 tests. Workspace Clippy, file/function/panic/bounded-operation guards,
formatting and diff checks passed. The initial failures and complete local test
outputs are retained in the
[enum evidence directory](../evidence/postgres-enum-results-2026-10-03/). At this
checkpoint automatic parameter inference and enum import/export/MCP consumers
were still open; the following section closes the named CSV import path.

### PostgreSQL custom-enum CSV import (October 3)

The CSV import plan initially emitted an untyped placeholder for a custom enum
column, even though it bound the row as text. The native PostgreSQL regression
first failed with a plan lacking the schema-qualified enum cast. The plan now
uses catalog metadata to cast the text parameter through the enum type.

The default CSV exporter writes both an empty enum label and SQL NULL as a blank
field. Because that file cannot distinguish the two values, the importer now
refuses blank cells for PostgreSQL enum columns when the NULL marker is empty.
The native contract verifies the target remains unchanged after refusal. With
an explicit `\N` marker, the same importer preserves an empty label, literal
`NULL`, Unicode, apostrophe and comma labels, and SQL NULL; PostgreSQL type and
value oracles confirm the restored rows.

The core unit suite passed 504 tests and the PostgreSQL integration suite passed
75 tests. Workspace Clippy, formatting, guards, ignored-test inventory and diff
checks passed. The first failure, result logs and fingerprints are in the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).
Other export encodings, automatic parameter inference and enum JSON/MCP
consumers remained open at this CSV checkpoint; the shared JSON renderer case
is covered in the following section. Automatic parameter inference and MCP delivery remain
open.

### PostgreSQL custom-enum JSON rendering (October 3)

A PostgreSQL 16 integration contract projects an enum column containing the
literal label `NULL`, an empty label, Unicode, and SQL NULL, and checks the
server-reported enum type for every row. The shared `render_json` serializer preserves the
labels as JSON strings, including `"NULL"` and `""`, while SQL NULL becomes
JSON null. The focused native selector passed; current source and output hashes
are recorded in the [enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

This proves the shared row-to-JSON result rendering for this PostgreSQL enum case.
MCP transport serialization, the file-writer path, automatic parameter
inference and other enum consumer/configuration combinations remain open under
ADR 0007.

### PostgreSQL custom-enum parameter type inference (October 3)

The native query/write contract first failed with SQLSTATE 42883 because a
custom enum comparison received a `TEXT` parameter. PostgreSQL now describes
parameter types from SQL context before binding text and SQL NULL values. When
the server infers a custom enum type, Bookie binds the original text bytes or
SQL NULL with that enum OID. If the SQL leaves the parameter ambiguous, the
driver retains the existing `Value` type; a plain text parameter remains TEXT.

The PostgreSQL 16 regression checks an enum label `NULL`, a SQL NULL match, a
direct update, a transactional update, an invalid label rejected with SQLSTATE
22P02, and an ordinary text parameter. Native `pg_typeof` and row postconditions
verify stored values and types. The before-fix `enum = text` failure and
after-fix focused result are recorded in the [enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

This closes text/SQL NULL inference where the server can determine a custom
enum parameter from the expression context. Other dynamic parameter types,
MCP delivery, the file-writer path, and additional enum configurations remain
open under ADR 0007.

### PostgreSQL custom-enum MCP and file export delivery (October 3)

A PostgreSQL 16 Docker contract sends enum rows through the production driver,
`McpBridge`, and the `execute_query` tool dispatcher. The fixture includes the
literal label `NULL`, an empty label, Unicode, and SQL NULL. The `execute_query`
response asserts exact JSON values, column order, non-truncated delivery, and
the server-reported `mcp_enum.state` type for every row. The same fixture checks
`export_data` JSON against those values and pins CSV output, where empty text is
quoted as `""` and SQL NULL is an unquoted blank. That CSV encoding is not a
lossless import promise: PostgreSQL enum import refuses ambiguous default blank
cells unless given a compatible explicit null marker. The core result-file writer
produces JSON preserving all four values and CSV with the same quoted-empty vs
blank-NULL convention. A cancellation after the first row preserves the previous
JSON destination and leaves no staging file. XML, HTML, and Markdown output now
have native enum contracts below; XLSX remains open under ADR 0007.

The ignored Docker selector, focused result, full PostgreSQL suite, and current
source/evidence hashes are recorded in the [enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum SQL file export restore (October 3)

A PostgreSQL 16 fixture exports custom-enum query rows through the core SQL
result-file writer, then replays each generated INSERT into a destination with
the same enum type. The native postcondition checks `pg_typeof` and exact values
for literal `NULL`, an empty label, Unicode, SQL NULL, and an apostrophe/
semicolon label shaped like a `DROP TABLE` statement. The destination table and
all five rows survive with the original values. The focused Docker contract and
complete PostgreSQL integration suite passed. XLSX enum file-writer behavior
remains open; this case does not establish generic
SQL export compatibility across unrelated destination schemas. See the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum XML file export (October 3)

A PostgreSQL 16 fixture sends custom-enum results through the core XML
file-writer. Native query assertions verify the server-reported enum type and
exact labels for literal `NULL`, empty text, Unicode, a markup-shaped label,
and SQL NULL. The output keeps empty text distinct from the explicit null
element and escapes markup, quotes, apostrophes, and entity text so a label
cannot create elements or be normalized into a different literal. The focused
Docker contract passed. XLSX remains a separate consumer;
this XML encoding is not an import/restore contract. See the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum HTML file export (October 3)

A PostgreSQL 16 fixture sends enum results through the core HTML file-writer.
Native rows verify exact labels and `pg_typeof` for literal `NULL`, empty text,
Unicode, a hostile image/event-handler label, and SQL NULL. The HTML keeps the
three null/empty/text outcomes distinct and escapes the hostile label as text,
with no raw image element emitted. The focused Docker contract passed. XLSX
remains a separate consumer; HTML output is not an import/restore
contract. See the [enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum Markdown file export (October 3)

A PostgreSQL 16 fixture sends custom-enum rows through the core Markdown
file-writer. Native row assertions verify `pg_typeof` and exact values for
literal `NULL`, empty text, Unicode, a pipe and newline, entity-looking text,
and SQL NULL. The initial export printed both the text label `NULL` and SQL
NULL as `NULL`; the retained before-fix output records that collision. Markdown
text cells now use JSON string quoting, while SQL NULL remains the unquoted
`NULL` marker. Cell characters that can split the table, form inline markup, or
look like HTML entities are escaped. The focused core and PostgreSQL tests
passed, followed by the complete PostgreSQL suite. Markdown output is an
explicit text encoding, not an import/restore contract. See the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL custom-enum XLSX file export (October 3)

A PostgreSQL 16 fixture verifies exact enum labels and `pg_typeof` for literal
`NULL`, Unicode, entity-looking text, formula-shaped text, SQL NULL, and an
empty label. Non-empty results produce an XLSX package; the core workbook test
checks that text labels, including `NULL` and `=1+1`, are stored as shared-string
cells, XML-sensitive characters remain text, and SQL NULL has no string cell.
The native fixture confirms that an empty enum label is refused at its exact
one-based row and column and that the existing workbook remains unchanged with
no staged file left behind. The XLSX format therefore supports the tested
non-empty enum labels as text and explicitly refuses empty enum labels; this is
not a general workbook import/restore claim. See the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### PostgreSQL money safe refusal

A PostgreSQL 16 contract returns a native `money` value with a separate exact
`money::numeric::text` oracle and server equality check. The driver reports
non-NULL money as `Undecodable`, SQL-literal and parameter consumers refuse the
marker, and SQL NULL remains `Value::Null`. This is an explicit safety boundary,
not exact money support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_postgres_money_is_refused_with_exact_server_oracle -- --include-ignored --exact --test-threads=1
```

The PostgreSQL 16 Docker contract passed.

### PostgreSQL geometric types: exact server oracle and visible refusal

A PostgreSQL 16 Docker contract checks the built-in `point`, `line`, `lseg`,
`box`, `path`, `polygon` and `circle` types. For each type, PostgreSQL supplies
an independent `pg_typeof` and `::text` oracle. Direct projections return the
matching `Undecodable` marker; SQL-literal and parameter consumers refuse that
marker. A separate NULL projection for every type remains `Value::Null`.

```sh
rtk cargo test -p tablepro-driver-postgres --test integration value_contract_geometric_types_keep_native_oracles_when_projection_is_refused -- --include-ignored --test-threads=1
```

The focused PostgreSQL Docker contract passed. The strict combined runner also
passed at `ab6c38442dbc5ef6f3a4d7e477df97dcb7b3a411`: 124 selected contracts
across 11 suites, with no missing suites. Report:
`target/quality/20260929T165940977032Z-values/report.json`. This establishes
explicit safe refusal, not geometry editing or exact shared-type support.

### PostgreSQL `citext` text consumer contract

The PostgreSQL 16 fixture creates the `citext` extension and checks that a
mixed-case address remains byte-for-byte text through result decoding, SQL
literal re-import and a typed parameter. A separate comparison against the
lowercase spelling confirms PostgreSQL still applies `citext`'s
case-insensitive comparison semantics. This establishes the label's text
fidelity without claiming that `citext` semantics are represented by `Value`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_citext_preserves_label_and_case_insensitive_comparison -- --include-ignored --exact --test-threads=1
```

The focused Docker contract passed.

### PostgreSQL keyed-update cast and parser mutation checkpoint, 2026-09-28

The shared keyed-update builder's final focused mutation report selected 16
mutations: 14 were caught, two were unviable compilation changes, and none
survived or timed out. A surviving `&& -> ||` mutation had shown that a typed
`Value::Decimal` could incorrectly receive the text cast. The new unit regression
requires typed numeric binds to keep `$1` and their native decimal parameter;
the same core suite also checks safe metadata handling at and beyond the 64-byte
allowlist input limit.

The app-parser check adds malformed-literal refusals to the wide numeric parser
contract. A fresh in-place run generated 28 mutations: 17 were caught, nine
survived and two cursor-increment mutations timed out. The survivors showed that
the existing wide decimal had both integer and fractional digits, leaving
integer-only, fractional-only and exponent paths unasserted. The parser
regression now checks all three with values too large for `rust_decimal`; the
updated run caught eight previously missed mutations. One prior survivor and
the two prior timeouts now all time out because `+=` to `*=` prevents cursor
advancement inside digit-scanning loops. These are non-terminating mutated
scanners, not surviving valid-input behavior; the 30-second mutant timeout
stopped each run. There are no surviving mutants. No production behavior changed.

```sh
rtk cargo mutants --dir . --package tablepro-core --file crates/core/src/sql_dialect.rs --re 'build_keyed_update|postgres_numeric_cast_type' --test-tool cargo --timeout 30 --build-timeout 120 --output target/quality/20260928-pg-keyed-update-cast-final -- --lib
rtk cargo mutants --in-place --dir . --package tablepro-app --file crates/app/src/ui/browse_tab/value_parse.rs --re 'is_postgres_numeric_literal' --test-tool cargo --timeout 30 --build-timeout 120 --iterate --output target/quality/20260929-pg-numeric-parser-resume-inplace -- --lib postgres_
```

Reports: `target/quality/20260928-pg-keyed-update-cast-final/mutants.out/outcomes.json`
and `target/quality/20260928-pg-numeric-parser-resume-inplace/mutants.out/outcomes.json`.
The updated parser regression passed, and the PostgreSQL Docker acceptance
contracts remain a separate server-side check.

### PostgreSQL NUMERIC special-value grid edit

The app's regular decimal parser rejects `NaN`, `Infinity`, and `-Infinity`.
Inline editing now keeps those three spellings as `Value::Text` only for the
PostgreSQL driver and decimal/numeric columns. The existing keyed-update builder
binds the text through `text` to the static `pg_catalog.numeric` target. The app
parser regression and PostgreSQL 16 integration case pass. The integration updates
one numeric column with each value and compares both decoded results and stored
values with the server's independent `amount::text` oracle. The app parser to
PostgreSQL composition test also parses each special spelling, applies the
keyed grid update, then compares the decoded value and `amount::text` result.

Focused checks:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib postgres_numeric_specials_remain_exact_text_only_for_postgres -- --test-threads=1
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration wide_numeric_contract::value_contract_numeric_special_grid_edits_match_server_text -- --include-ignored --exact --test-threads=1
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib postgres_numeric_parser_outputs_round_trip_through_server -- --include-ignored --test-threads=1
```

The composed parser-to-server test passed against the PostgreSQL 16 Docker fixture.

## PostgreSQL array checkpoint

Scenario B3-1 follows the DBeaver array distinctions recorded in the
[external survey](b3-test-scenario-survey.md). The first real-server regression
failed on an empty int4 array, which returned Undecodable. No external fixture
or source code was copied.

The driver now decodes binary arrays of bool, int2/int4/int8, oid, text/name/
varchar/bpchar, float4/float8, numeric, UUID and bytea. IPv6 `inet[]` remains
an explicit safe refusal even though PostgreSQL's type, text, JSON and element
oracles are covered. Results use PostgreSQL array
text in Value::Text and retain the original array type in ColumnInfo. Whole-array
NULL remains Value::Null. Nested braces and explicit bounds preserve dimensions;
quoted elements distinguish NULL, literal NULL, empty strings and escaped text.
JSON export retains this text representation, not a flattened JSON array.

The regression compares PostgreSQL array_send bytes after SQL literal re-import,
explicitly typed parameter binding and execution of generated INSERT exports.
It also checks session/direct parity, exact column type and JSON string fidelity.
The corpus includes six dimensions, non-default lower bounds, Unicode, quotes,
backslashes, newline and SQL-shaped text, numeric scale/wide fractions, signed
zero, NaN/infinities, empty binary values and integer boundaries.

Unit tests reject truncated/trailing data, invalid dimensions or element lengths,
OID mismatches, invalid UTF-8 and NULL flags, unsupported element types and
size/product overflow. Deterministic malformed-input and header-mutation cases
exercise bounded decoding. Binary-to-text array decoding is capped at 16 MiB; exceeding the
limit returns the existing visible undecodable marker rather than truncated data.

Limits: network, enum/domain/composite/range and most JSON/BSON array element
contracts remain unsupported or untested; grid edits are verified only for
boolean[], bytea[], uuid[], timestamptz[], integer[], text[], numeric[] and float8[], and the full grid/MCP/import
acceptance matrix remains open. Binding text in these tests uses an explicit
PostgreSQL array cast; this does not establish automatic array parameter typing.

Test locations: `crates/drivers/postgres/src/array.rs` and
`crates/drivers/postgres/tests/support/array_contract.rs`, invoked by the ignored
`value_contract_arrays_preserve_elements_dimensions_and_exports` integration test.
The shared value runner selects this test automatically.

The 2026-09-28 P1 reconciliation added a Docker-backed acceptance test in
`crates/drivers/postgres/tests/support/array_contract.rs`,
`array_contract::value_contract_array_grid_edit_preserves_array_elements`, for an
`integer[]` grid edit containing NULL. With Docker access, it reproduced SQLSTATE
42804: the generated UPDATE assigned a TEXT parameter to an `integer[]` column.
The shared keyed-update builder now casts text through `text` to a fixed,
allowlisted PostgreSQL built-in array type. Database metadata is never interpolated
into SQL. PostgreSQL verified the edited value with a typed array comparison;
NULL remained an array NULL element.

The same retained integration case now also checks a `boolean[]` edit. The app
parser preserves `{true,false,NULL}` as text, the update builder casts through
`text` to `pg_catalog.bool[]`, and PostgreSQL's native array text and
`array_send` bytes match after the edit. A second row's original wire bytes
remain unchanged. This expands the server-backed edit matrix to boolean[] as
well as integer[], text[], numeric[] and float8[]. The full PostgreSQL integration
suite passed 64 tests in 119.45 seconds. The strict GTK + DuckDB value runner
later passed 154 selected tests across all 11 suites with no missing suites.
Its current report is `target/quality/20260930T174541378362Z-values/report.json`
(`dirty: true`, based on `9cc0bbb`); the six PostgreSQL array parser tests are
included in the 21 app tests selected by the strict runner.

```sh
rtk cargo test --locked -p tablepro-app --lib value_contract_postgres_boolean_array_grid_literal_stays_text_through_the_keyed_update_builder -- --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_array_grid_edit_preserves_array_elements -- --include-ignored --exact --test-threads=1
```

The same server-backed array-edit contract also round-trips a `bytea[]` value
with two escaped byte elements, an empty byte string and NULL. The app parser
preserves the array literal as exact text, the builder emits the fixed
`pg_catalog.bytea[]` cast, and the edited row matches PostgreSQL's independent
`array_send` bytes; a sibling row's wire bytes remain unchanged. The focused
app-parser and Docker integration tests passed. The strict shared-value report
above includes this bytea[] contract.

A separate result/binding contract covers arrays of a domain over `bytea`. It
checks declared domain-array metadata, a non-UTF-8 element, an empty element, a
NULL element, SQL NULL versus an empty array, and native JSON/`array_send`
oracles after qualified text binding and keyed edit. A domain CHECK violation
returns `23514` and leaves both the edited row and its sibling unchanged. The
focused Docker test and full PostgreSQL integration suite passed; see the
[source-fingerprinted evidence](../evidence/postgres-domain-bytea-array-results-2026-10-04/manifest.json).

The UUID[] edit exposed a parser bug: `classify_type` matched the `uuid`
substring before accounting for PostgreSQL array metadata, so it tried to parse
the entire `{...}` literal as one UUID. PostgreSQL `[]` metadata now stays text
before scalar classification. The app test checks parsing and keyed-update SQL;
the Docker test compares the edited array's native `array_send` bytes with an
independent server array and confirms the sibling row is unchanged. Both focused
tests passed. The strict GTK + DuckDB runner passed 154 selected tests across
all 11 suites with no missing suites:
`target/quality/20260930T174541378362Z-values/report.json`.
An additional app parser matrix checks that UUID, date, time, numeric, boolean,
and timestamptz array metadata preserve the complete literal as text. The full
app library suite passed 413 tests, with 12 existing ignored tests.
Removing the PostgreSQL array guard made this matrix fail on `uuid[]` with the
scalar UUID parser error; restoring it made the test pass. The targeted
cargo-mutants report generated one whole-function replacement, which was
unviable because `TypeKind` does not implement `Default`; it did not count as a
caught mutant. Report: `target/quality/20260930-pg-array-type-parser-mutants-cached/`.

A PostgreSQL `timestamptz[]` grid edit now carries two offset-origin values with
six fractional digits plus NULL through the app parser and keyed-update cast.
The Docker contract compares the stored value's native `array_send` bytes with
an independently constructed timestamptz array and confirms the sibling row's
wire bytes are unchanged. The app parser/builder test and PostgreSQL integration
contract both pass.

```sh
rtk cargo test --manifest-path linux/crates/app/Cargo.toml value_contract_postgres_timestamptz_array_grid_literal_stays_text_through_the_keyed_update_builder
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration array_contract::value_contract_array_grid_edit_preserves_array_elements -- --include-ignored --exact --test-threads=1
```

```sh
rtk cargo test --manifest-path linux/crates/app/Cargo.toml value_contract_postgres_uuid_array_grid_literal_stays_text_through_the_keyed_update_builder
rtk cargo test --manifest-path linux/crates/drivers/postgres/Cargo.toml --test integration value_contract_array_grid_edit_preserves_array_elements -- --include-ignored
```

```sh
rtk cargo test --locked -p tablepro-app --lib value_contract_postgres_bytea_array_grid_literal_keeps_escaped_bytes_through_the_builder -- --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_array_grid_edit_preserves_array_elements -- --include-ignored --exact --test-threads=1
```

### PostgreSQL array cast allowlist mutation follow-up, 2026-09-30

The hosted core-1 mutation shard exposed missing assertions for the less common
allowlisted array casts. The core regression now enumerates every built-in alias,
checks the exact generated static cast for keyed updates, and rejects unknown
types, SQL-shaped metadata, and malformed precision modifiers. A scoped
`cargo-mutants` run generated 26 mutants for `postgres_array_cast_type`; all 26
were caught, with no missed, timed-out or unviable mutants. This proves the
builder mapping and refusal boundary, not a native-server round trip for every
array type.

```sh
rtk cargo test --locked -p tablepro-core --lib postgres_array_update_casts_allowlist_type_metadata
rtk cargo mutants --dir . --package tablepro-core --file crates/core/src/sql_dialect.rs --re 'postgres_array_cast_type' --test-tool cargo --timeout 30 --build-timeout 120 --output target/quality/20260930-postgres-array-cast-mutants -- --lib postgres_array_update_casts_allowlist_type_metadata
```

The scoped mutation report is at
`target/quality/20260930-postgres-array-cast-mutants/mutants.out/outcomes.json`.

A focused mutation run on the PostgreSQL array wire decoder generated 13 mutants
for `decode_binary`; all 13 were caught by the library contracts, with no misses,
timeouts or unviable mutants. The hosted quality run at SHA
`8ed0f66ed54b1411feaac5d7a8e49abc6999fb18` did not reach mutation testing for
this crate: its baseline command ran the full Docker value suite and timed out
at 60 seconds while still executing. The CI job now runs decoder mutations
against the unit suite; Docker-backed server oracles remain in Build Linux.
Focused report: `target/quality/20260930-postgres-decode-binary-mutants/mutants.out/outcomes.json`.

The focused core cast and hostile-metadata tests passed. The Docker-backed
PostgreSQL regression passed after the fix:

```sh
cargo test --locked -p tablepro-core --lib postgres_array_update
cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_array_grid_edit_preserves_array_elements -- --include-ignored --exact --test-threads=1
```

The expanded server test adds a `text[]` edit through the unchanged app text
parser and shared `text` to `pg_catalog.text[]` cast. Its value includes NULL and an
element containing a quote, backslash and comma. An independent `unnest` query
with ordinality checks each element and a separate NULL flag. The app
parser-to-builder unit, focused core cast test, and expanded integration test
passed against PostgreSQL.

Exact grid editing is server-verified for `boolean[]`, `bytea[]`, `uuid[]`, `timestamptz[]`, `integer[]`,
`text[]`, `numeric[]` and `float8[]`. JSON and other
unsupported element OIDs, custom/user-defined arrays
and automatic array parameter typing remain outside the tested support surface.
B3 remains open.

A separate `numeric[]` grid contract now feeds an exact literal containing a
wide numeric with 20 fractional digits, a scale-preserving `1.2300`, NaN,
positive and negative Infinity, and a NULL element through the shared numeric[]
cast. Its independent server oracle unnests with ordinality, checks NULL
separately, and compares every element as `numeric::text`. The app
parser-to-builder unit, PostgreSQL scalar numeric decoder unit, escaped-text
array unit, and Docker-backed numeric[] grid assertion passed against PostgreSQL.

The `jsonb[]` refusal contract checks a native JSONB array containing an object
and JSON null. PostgreSQL independently reports the `jsonb[]` type, its exact
`array_to_json(... )::text`, and semantic JSONB equality. BookiE returns an
`Undecodable` marker and refuses both SQL literal rendering and parameter
binding. This records a precise unsupported boundary; it does not add JSON-array
support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration array_contract::value_contract_json_array_elements_are_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The PostgreSQL 16 Docker contract passed.

The neighboring `json[]` contract uses the same refusal boundary with a native
JSON array containing an object and JSON `null`. The server reports `json[]`,
returns exact `array_to_json` text, and independently confirms semantic
equality after conversion to `jsonb`. The driver returns `Undecodable`; SQL
literal rendering and parameter binding refuse it. JSON and JSONB array support
is not claimed.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration array_contract::value_contract_json_text_array_is_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The PostgreSQL 16 Docker contract passed.

### PostgreSQL float8[] grid edit at floating-point boundaries, 2026-09-30

The app parser keeps a float8[] grid literal as exact text, and the keyed-update
builder casts it through `text` to the fixed `pg_catalog.float8[]` type. A
PostgreSQL 16 Docker contract edits values containing the adjacent float above
1.0, negative zero, the minimum positive subnormal, NaN, both infinities and
NULL. It compares the stored array text and `array_send` bytes with an
independently constructed native array oracle, verifies the update affects one
row, and confirms a sibling row is unchanged. The focused parser, grid-edit and
full PostgreSQL integration tests passed; the latest full run passed 64 tests
in 119.12 seconds.

The consumer follow-up exercised CSV export, CSV parsing, typed row conversion,
and keyed write-back for the same float8[] result. It found that the generic
CSV importer classified `float8[]` by its element type and rejected the array
cell as `NotANumber`. Array-shaped catalog types now remain exact text during
CSV import. The live round-trip compares the restored row's `array_send` bytes
to the original and checks a third row remains unchanged. SQLx formats numeric
array elements with quotes while PostgreSQL `float8[]::text` does not; the
contract therefore checks exported/imported driver text exactly and uses
native wire bytes, rather than display-string equality, as the stored-value
oracle. The scoped mutation test caught the sole mutation of the changed array
classification condition (1/1). A wider classifier mutation pass initially
exposed missing coverage for the `BLOB` and `BINARY` byte-type aliases; the
catalog contract now pins those spellings, plus `VARBINARY` and `IMAGE`. The
final classifier run caught 13 of 14 mutants, with one unviable replacement and
no survivors or timeouts. After the array fix, the strict GTK + DuckDB value
runner passed 154 tests across all 11 suites with no missing suites; its latest
report is `target/quality/20260930T174541378362Z-values/report.json` (run against
dirty working-tree changes based on `9cc0bbb`).

```sh
rtk cargo test --locked -p tablepro-app --lib value_contract_postgres_float8_array_grid_literal_keeps_subnormal_and_signed_zero_text -- --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_float8_array_grid_edit_preserves_special_and_adjacent_values -- --include-ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration -- --include-ignored --test-threads=1
rtk cargo test --locked -p tablepro-core postgres_array_csv_cells_remain_text_instead_of_being_parsed_as_scalars
rtk cargo mutants --dir linux --package tablepro-core --file crates/core/src/import/cell.rs --re 'cell.rs:86:' --test-tool cargo --timeout 30 --build-timeout 180 --output linux/target/quality/20260930-postgres-array-csv-import-mutants-line -- --lib postgres_array_csv_cells_remain_text_instead_of_being_parsed_as_scalars -- --test-threads=1
rtk cargo mutants --dir linux --package tablepro-core --file crates/core/src/import/cell.rs --re 'column_kind' --test-tool cargo --timeout 30 --build-timeout 180 --output linux/target/quality/20260930-csv-import-column-kind-mutants-followup -- --lib a_catalog_type_name_reads_as_the_value_shape_it_stores -- --test-threads=1
```

### PostgreSQL float8[] typed CSV INSERT, 2026-10-01

A failing-first extension tested the actual typed INSERT plan after CSV parsing,
not only parser-to-keyed-update behavior. PostgreSQL rejected the array cell
with SQLSTATE `42804` because the import bound it as TEXT. Import plans now use
the same fixed `pg_catalog` allowlist cast as keyed updates for textual array
parameters. The live PostgreSQL 16 test imports a special-value `float8[]` into
a separate table and checks exact `array_send` bytes against the source oracle.
The encompassing contract also retains original and sibling row identities
through the keyed edit.
The focused Docker regression passed.

Mutation testing caught 33 viable SQL-dialect mutations (2 unviable) and 22
viable import-plan mutations (1 unviable), with no survivors or timeouts. The
strict GTK+DuckDB values layer passed 174 selected tests across all 11 suites,
with no missing suites:
`20261001T024828271108Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T024828271108Z-values/report.json`).

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration value_contract_float8_array_grid_edit_preserves_special_and_adjacent_values -- --include-ignored --test-threads=1
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/sql_dialect.rs --re 'postgres_array_cast_type|build_insert_from_draft' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-postgres-array-insert-mutants -- --lib
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/import/plan.rs --re 'insert_statement|bind_rows' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-postgres-array-import-plan-mutants -- --lib import::
```

### PostgreSQL IPv6 `inet[]` explicit refusal

A PostgreSQL 16 contract returns an IPv6 `inet[]` containing a host-prefix
address, a network-prefix address, and NULL. The driver reports the array as
`Undecodable("INET[]")`; PostgreSQL independently reports its native type,
exact array text, JSON representation, element host/prefix/family values, and
equal `array_send` bytes after server-side text re-import. SQL-literal and
parameter consumers refuse the undecodable marker, while a NULL array remains
`Value::Null`. This records the current safe boundary without claiming network
array support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-postgres --test integration value_contract_ipv6_inet_array_is_explicitly_unsupported -- --include-ignored --exact --test-threads=1
```

The focused PostgreSQL 16 Docker contract passed.

## ClickHouse wide integer parser contract, 2026-09-28

ClickHouse `Int128` and `UInt128` values cannot fit `Value::Int`. A local
regression feeds the unquoted JSON integer tokens for signed minimum, signed
maximum and unsigned maximum through the same `parse_line` and `response_row`
functions used by the driver. All three remain exact `Value::Text`. This verifies
the parser boundary with `serde_json`'s `arbitrary_precision` feature enabled.
The real-server query contract below separately checks native result decoding.

The focused unit command passed, and the mapped change-contract gate passed all
four ClickHouse response regressions. Its report is
`target/quality/20260928T113903658583Z-change-contracts/report.json`.

```sh
cargo test --locked -p tablepro-driver-clickhouse --lib clickhouse_json_row_preserves_wide_integer_tokens_exactly
```

Protocol references: [PostgreSQL arrays](https://www.postgresql.org/docs/16/arrays.html)
and [array_send](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/adt/arrayfuncs.c).

### ClickHouse wide integer result, binding and SQL re-import, 2026-09-28

The signed Int128 minimum and maximum and unsigned UInt128 maximum pass through
text-valued bound parameters into native Int128/UInt128 columns and return as
exact `Value::Text`. The result row is written with the shared generated INSERT
literal, executed into matching native columns, and read back as the exact
original text. The same real-server result passes through CSV export, the shared
CSV reader and typed import cell parser both with formula sanitization disabled
and with default formula sanitization. The default-mode import is bound into a
second native Int128/UInt128 table and read back from ClickHouse to verify the
stored digits. Default export prefixes the negative
Int128 with an apostrophe; import removes that marker only when the column type
is exactly Int128 or UInt128 and the remaining signed digits fit that type.
Ordinary text, invalid values, unsigned negatives and overflow retain the
apostrophe. This preserves formula protection for other text columns while the
three wide integer fields re-import as their exact original text. The first
import attempt exposed two issues: `Int128` was classified as i64, then the
formula-safe apostrophe remained in text-backed wide integers. Both import paths
are now covered.

```sh
cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration wide_integer_binding_and_sql_export_preserve_exact_server_values -- --include-ignored --exact --test-threads=1
```

The CSV round trip covers this wide-integer result path with formula
sanitization both disabled and enabled. The grid contract also covers the four
adjacent wide-integer boundaries:
Int128 minimum to minimum+1, Int128 maximum to maximum-1, UInt128 zero to one,
and UInt128 maximum to maximum-1. Other export formats remain open.

### ClickHouse nested value consumer boundary, 2026-09-30

The live contract covers seven nested Array/Map/Tuple shapes: the three base
forms plus Array(Map), Map(Array), Tuple(Array), and Map(Tuple). Each value is
compared with ClickHouse's native `toTypeName` and `toJSONString` oracles, including
wide unsigned values that JSON must quote. A plain `Value::Json` no longer
carries the native type needed to distinguish numeric strings from text
strings, so SQL-literal export and parameter binding explicitly refuse all
seven nested shapes instead of writing a changed value. Each shape also goes
through the keyed grid-update builder against a real MergeTree row: the driver
returns `Transaction { statement_index: 0, source: Unsupported }`, and the
stored id, value, native type and server JSON remain unchanged. The original
array case retains its direct cell-literal refusal contract too.

The focused Docker integration case and the complete ClickHouse Docker suite
passed (33 tests). The expanded focused case verifies refusal for all seven
grid edits; its ignored test is listed in `docs/ignored-tests.md`.

The two exporter refusal tests also passed scoped mutation checks: the shared
renderer caught all three selected mutations, including making the ClickHouse
guard unconditional; the ClickHouse grid renderer caught both selected
function-replacement mutations. Reports are in
`target/quality/20260929-clickhouse-json-mutants-core-final/mutants.out/outcomes.json`
and
`target/quality/20260929-clickhouse-grid-json-mutants-lib-only-final/mutants.out/outcomes.json`.
The new seven-shape real-grid refusal contract also caught both selected
whole-function renderer mutations, with no missed, timed-out or unviable cases:
`target/quality/20260930-clickhouse-nested-grid-refusal-mutants/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration nested_values::value_contract_nested_collections_keep_exact_json_and_refuse_lossy_consumers -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration -- --include-ignored --test-threads=1
```

### ClickHouse Int128 and UInt128 grid edits, 2026-09-28

A real-server keyed update changes both rows through the same shared builder
used by the grid save path. It moves Int128 minimum to minimum+1 and UInt128
maximum to maximum-1, then Int128 maximum to maximum-1 and UInt128 zero to one.
The independent result query compares all four exact text values and verifies
the non-target row remains unchanged after each edit.

```sh
cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration wide_integer_grid_edits_preserve_exact_values_and_row_identity -- --include-ignored --exact --test-threads=1
```

Validation on the working tree based on `7cb2fe3ca`: all 50 PostgreSQL
unit/integration tests passed. The full local gate passed at
`target/quality/20260926T204949649377Z-full/report.json`; Debian package validation
was skipped because `dpkg-deb` is unavailable. The subsequent shared run caught
an overly literal metadata expectation: SQLx names PostgreSQL bpchar arrays
`CHAR[]`. After correcting that assertion, all 11 suites passed at
`target/quality/20260926T205412392759Z-values/report.json`, including all eight
drivers, GTK and DuckDB. That run reused 744 artifacts, rebuilt one package and
spent 3.034 seconds compiling. Function/file size guards and whitespace checks
also passed. Installed desktop acceptance remains a later gate.

## PostgreSQL time checkpoint

B3-2 adopts the temporal-boundary scenarios from the
[external survey](b3-test-scenario-survey.md). The new server regression first
failed because `24:00:00` was decoded as midnight: exported wire bytes changed
from `000000141dd76000` to `0000000000000000`.

Binary time decoding now retains ordinary times as typed values, preserves
`24:00:00` as exact text, and represents timetz as text with its stored signed
offset, including seconds. Column metadata retains TIME/TIMETZ. NULL remains
NULL. Invalid wire lengths, out-of-range times and offsets are refused.

Eleven cases run under UTC, Asia/Kathmandu and America/New_York, covering
microseconds, end-of-day and both offset extremes. Tests compare time_send or
timetz_send bytes after SQL literal re-import, explicitly typed bindings and
generated INSERT exports. Direct/session parity, type metadata and JSON text
fidelity are asserted. The permanent test is
`value_contract_times_preserve_midnight_fraction_and_offset`; malformed-wire and
boundary units live in `crates/drivers/postgres/src/temporal.rs`.

This checkpoint does not establish editing support for text-backed time values,
temporal arrays, BC/large-year dates, infinities, mixed intervals or every
grid/MCP/XLSX consumer. Those B3 cases remain open. Protocol references:
[date/time types](https://www.postgresql.org/docs/16/datatype-datetime.html) and
[time/timetz send and receive](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/adt/date.c).

Fresh cargo-mutants 27.1.0 evidence, on the working tree based on `6de5351ee`:

| Scope | Result | Report beneath target/quality |
| --- | --- | --- |
| Array decode entry, scalar elements and float rendering, 26 generated mutations | 24 caught, 1 survivor, 1 unviable | `20260926-b3-array-mutants/mutants.out/outcomes.json` |
| Array survivor after including malformed-input unit tests | 1 caught, no survivors/timeouts | `20260926-b3-array-mutants-followup/mutants.out/outcomes.json` |
| Complete new time decoder, 22 generated mutations | 21 caught, 1 unviable, no survivors/timeouts | `20260926-b3-time-mutants/mutants.out/outcomes.json` |

The array survivor removed the NUL-byte guard. Its existing unit regression was
omitted by the mutation run's `value_contract` filter; array/numeric malformed
units now share that prefix. The rerun caught the mutation. Both unviable changes
attempted to construct a nonexistent default Value and failed compilation; they
are not test catches. These were scratch-source runs reusing the local target
directory, with no concurrent Cargo build. The time mutation run used unit tests;
array runs also used the real-server value contracts. This is scoped evidence,
not a complete array, numeric, workspace or hosted mutation pass.

Local validation: `target/quality/20260926T210713778702Z-full/report.json`
passed formatting, Clippy, unit and sandbox checks. Debian package validation
was skipped because `dpkg-deb` is unavailable. The stricter shared runner passed
all 11 selected suites at
`target/quality/20260926T210925595822Z-values/report.json`, including four
PostgreSQL server contracts and all eight drivers with GTK/DuckDB selected.
The complete PostgreSQL unit/integration run also passed all 53 tests.
Ten runner/workflow regression tests passed, including a later refinement that
rejects a mutation report containing only unviable changes. Workflow YAML parsed;
the mutation summary shell was executed against complete, missing, empty and
unviable-only fixture reports. Function/file size and whitespace guards passed.
Hosted mutation/coverage execution and installed desktop acceptance remain
separate from these local results.

## PostgreSQL era and mutation checkpoint

The BC regression reproduced an export failure: `0001-01-01 BC` became the
invalid PostgreSQL literal `0000-01-01`. PostgreSQL SQL rendering now uses era
years and a BC suffix, and removes the ISO leading plus for years above 9999.
Other dialects and ordinary AD formatting retain their existing contracts.
Fifteen server cases run in three session time zones, covering BC dates,
large representable years, microseconds, the PostgreSQL epoch boundary and both
instants of a repeated DST hour. Direct/session values, type metadata, typed
bindings, SQL literals and generated INSERTs are compared with server wire bytes.
The integration test is `value_contract_dates_preserve_eras_large_years_and_instants`;
its lowest-tier regression is in core's SQL literal tests. Dates outside chrono's
range now have native text/wire oracles, visible JSON/CSV refusal markers, and
explicit SQL-literal/parameter refusal. They still lack exact application value
support. Infinities, mixed intervals, temporal arrays and non-SQL consumer/editing
acceptance remain open.

At this checkpoint, the extended-calendar contract parsed DATE and TIMESTAMP
exports back through the CSV reader and checked visible `<undecodable DATE>` and
`<undecodable TIMESTAMP>` markers; JSON output was checked as structured JSON.
The October 3 continuation below supersedes that refusal status for the named
DATE, TIMESTAMP and TIMESTAMPTZ ranges with exact-value consumer support.

The PostgreSQL temporal infinity test then exposed a default CSV formula marker
that typed import rejected for `-infinity`. Import now removes the marker only
for recognized PostgreSQL temporal sentinels. Import plans cast consistent text
parameters to the destination temporal type, and integration coverage confirms
native re-import of positive/negative infinities, `TIME '24:00:00'`, and
`TIMETZ` with offset seconds. The complete PostgreSQL integration target passed
64 tests. Core import/planner and SQL-dialect suites passed 81 and 45 tests:

Scoped mutation testing caught all 19 viable changes in the PostgreSQL
temporal CSV classifier (5 unviable), all 21 viable import-plan mutations (1
unviable), and all 15 viable SQL insert-cast mutations (2 unviable), with no
survivors or timeouts. Reports:
`import classifier` (raw report unavailable in this checkout: `../target/quality/20261001-postgres-temporal-import-mutants-final/mutants.out/outcomes.json`),
`import plan` (raw report unavailable in this checkout: `../target/quality/20261001-postgres-temporal-import-plan-mutants-final2/mutants.out/outcomes.json`),
`SQL insert casts` (raw report unavailable in this checkout: `../target/quality/20261001-postgres-temporal-insert-mutants-final/mutants.out/outcomes.json`).

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration value_contract_temporal_infinities_remain_distinct_from_null -- --ignored --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration value_contract_times_preserve_midnight_fraction_and_offset -- --ignored --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration -- --include-ignored --test-threads=1
```

The strict GTK+DuckDB values layer then passed 169 selected tests across all 11
suites, with no missing suites:
`20261001T023544965607Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T023544965607Z-values/report.json`).

Reproduce the mutation scopes:

```sh
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/import/cell.rs --re 'postgres_text_temporal|value_for' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-postgres-temporal-import-mutants-final -- --lib import::
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/import/plan.rs --re 'insert_statement|bind_rows' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-postgres-temporal-import-plan-mutants-final2 -- --lib import::
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/sql_dialect.rs --re 'postgres_temporal_cast_type|build_insert_from_draft' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-postgres-temporal-insert-mutants-final -- --lib
```

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration value_contract_dates_preserve_eras_large_years_and_instants -- --ignored --test-threads=1
```

The [CI audit](ci-audit-2026-09-27.md) found nine survivors in the broader hosted
PostgreSQL mutation run. New regressions use an independent 16,777,216-byte limit,
test exact quoted-output and raw-element boundaries, check dimension rejection
before decoding, reject fractional groups beyond declared scale and preserve
one-digit fractions and noncanonical numeric text. Bounded element reading is
now a directly testable helper; the size policy is unchanged. No mutation was
blanket-excluded.

Local cargo-mutants 27.1.0 evidence, working tree based on `c57ac7715`:

| Scope | Result | Report beneath target/quality |
| --- | --- | --- |
| Changed SQL date renderer | 10 caught, 1 unviable, no survivors/timeouts | `20260926-b3-date-mutants/mutants.out/outcomes.json` |
| Array/numeric functions implicated by hosted survivors | 58 caught, 1 additional unit-only survivor, 3 unviable | `20260927-b3-pg-survivors/mutants.out/outcomes.json` |
| Numeric type survivor after independent-oracle correction | 1 caught, no survivors/timeouts | `20260927-b3-numeric-type-followup/mutants.out/outcomes.json` |

The additional survivor changed normal numerics from Decimal to Text. The unit
test reused decode_text as its own expected-value oracle; it now asserts the
independent value, variant and decimal text. The server contract already covered
this type distinction. Unviable mutations are compilation failures, not catches.
Diff-scoped mutation listing required workspace-relative paths and explicit
`--src-prefix=a/ --dst-prefix=b/` because the local Git mnemonic prefixes produced
an empty selection. The list was checked before executing the 11 date mutations.

Final local validation for this checkpoint: formatting, Clippy, unit and sandbox
checks passed at `target/quality/20260926T231119112831Z-full/report.json`.
All 11 selected value-contract suites passed at
`target/quality/20260926T231558864082Z-values/report.json`, including all eight
drivers, GTK, DuckDB, nine core contracts and five PostgreSQL server contracts.
Compilation reused 707 artifacts and rebuilt 17 affected packages in 39.688s.
All eight SSH fixture tests and 15 runner/workflow regression tests passed.
The complete PostgreSQL unit/integration suite passed all 55 tests with ignored
fixture tests explicitly enabled (`--include-ignored --test-threads=1`).
Hosted execution, the broader core mutation backlog and installed desktop
acceptance remain separate gates.

## XLSX temporal consumer checkpoint, 2026-09-27

Workbook XML regressions reproduced that temporal values were forced into
spreadsheet serial cells: fractional seconds were displayed with whole-second
formats, timezone-bearing timestamps lost their explicit UTC identity, and
dates outside the native spreadsheet range lacked a text fallback. Exports now
write fractional Time/DateTime values, every TimestampTz and dates/timestamps
outside 1900–9999 as exact text using the existing canonical export spelling.
Supported dates and whole-second values retain native cells. Text timestamps
include their UTC offset; the two distinct instants in a repeated DST hour stay
distinct. This intentionally trades spreadsheet date arithmetic for exact text
when the native cell cannot carry the contract.

A timestamp originating at `+05:30` with nine fractional digits is also checked
in the XLSX shared string. The emitted canonical UTC text is
`2026-09-27T07:04:56.123456789+00:00`, preserving the exact instant across the
offset conversion; the corresponding CSV typed-import contract independently
checks the same instant.

Three added unit contracts inspect ZIP worksheet/shared-string XML: temporal
fallbacks, native boundary dates/whole-second cells, and finite/nonfinite floats
versus NULL. The temporal test failed before the fix. Eight XLSX unit tests pass.
This does not establish every IEEE floating-point rounding behavior, arbitrary
precision editing, temporal arrays or all remaining consumer/driver types.

Cargo-mutants selected 15 mutations in the complete XLSX cell writer. All 15 were
caught, with no missed, timeout or unviable outcomes. Evidence:
`target/quality/20260927-b3-xlsx-temporal-mutants/mutants.out/outcomes.json`.
This includes both finite-float guard survivors from hosted run `36280114335`;
row/column error-path and other export survivors remain separate triage work.

The shared eight-driver runner passed all 11 suites, including 12 core value
contracts, at `target/quality/20260927T091952740079Z-values/report.json`.
All 19 installed release-build UI scenarios passed and wrote successful result
JSON files under `target/quality/20260927-b3-xlsx-ui/`. The layer report
`target/quality/20260927T091941354836Z-layers/report.json` intentionally remains
failed: its initial full gate caught two unnecessary clones in the new tests,
while the independent value/UI layers passed. The clones were corrected rather
than suppressing Clippy. Thirty Python harness tests passed, including both
successful and failed GTK artifact-production regressions.
The corrected full gate passed at
`target/quality/20260927T092738833389Z-layers/report.json` (formatting, Clippy,
workspace unit/binary tests and sandbox regressions). Hosted execution and
installed Wayland/package acceptance remain separate from these local checks.

## Workbook UI and failure-boundary checkpoint, 2026-09-27

Three default installed-GTK scenarios exercise keyboard format selection and the
real save chooser: exact typed SQLite export, save cancellation, and visible
empty-text refusal. The XML oracle checks wide signed integers, nanosecond
precision, dates outside 1900–9999, native numeric dates/times, NULL, infinity,
formula-like Unicode text and the 100-row page boundary. Every scenario compares
all source rows before and after. Four Python tests cover oracle failures,
formula rejection and default scenario registration.

The expanded UI corpus found a new defect: rust_xlsxwriter discards empty strings,
so successful workbook export silently collapsed empty text into missing cells.
The initial combined report `target/quality/20260927T094125010168Z-layers/report.json`
therefore remains failed, with full/value layers passed and the UI assertion
failing on the missing cell. A core regression also failed before correction.
Workbook export now refuses empty text with its one-based data row/column and
CSV/JSON alternatives. The dedicated UI scenario requires that visible error,
no published file and no temporary export. A public core regression separately
requires existing destination bytes to survive this refusal. This is an explicit
format limitation, not a claim that XLSX now round-trips empty text.

Coordinate regressions also reproduced accepting column 16,385 in the converter.
The writer now checks the actual worksheet limits before narrowing coordinates,
reserves the header row, and saturates diagnostic counts instead of overflowing.
Public file tests cover column-limit refusal and cancellation after a row has
been written; both leave existing destination bytes intact and no temporary file.

Final local evidence for this checkpoint:

- `target/quality/20260927T095051662483Z-layers/report.json`: full, values, UI and
  harness layers all passed; 34 Python harness tests passed.
- `target/quality/20260927T095333331615Z-values/report.json`: all 11 suites passed,
  including eight drivers, GTK, DuckDB and 16 core value contracts.
- `target/quality/20260927-b3-workbook-ui-corrected/`: all 22 installed release
  scenarios passed, with 22 result JSON files and 22 stderr artifacts.
- `target/quality/20260927-b3-xlsx-refusal-mutants/mutants.out/outcomes.json`:
  all 11 selected `write_row`/`cell_column` mutations caught; no missed, timeout or
  unviable outcomes. This final run includes the empty-text refusal and supersedes
  the earlier seven-coordinate-mutation run for this checkpoint.

These are local X11/AT-SPI and fixture results. Hosted CI, network-database temporal
UI scenarios, installed Wayland/package acceptance and the remaining B3 type and
consumer contracts remain separate work.

## Mixed bindings and failure propagation checkpoint, 2026-09-27

The shared SQL contract now passes named parameters through extraction, typed
input parsing, placeholder generation, driver binding and server decoding in one
query. Each of PostgreSQL, MySQL, SQL Server, ClickHouse, SQLite and DuckDB checks
three adversarial payloads across repeated names and mixed types. Expected rows
are constructed independently of the binding list. Quoted/commented colon names
must not become parameters. Redis and MongoDB continue their protocol-specific
contracts rather than receiving synthetic SQL scenarios.

Two installed GTK scenarios check committed rows: repeated parameters preserve
signed integer limits and SQL-like Unicode data; cancellation writes nothing and
a retry uses replacement values. Lexer regressions cover nested PostgreSQL
comments/dollar quotes, MySQL escaped quotes and SQL Server escaped identifiers.
Explicit text parsing retains whitespace and numeric/placeholder-looking text.

Transport regressions cover all explicit TLS modes against both legacy TLS flags,
CA paths, connection identity, authentication and timeout propagation. Local
sockets refuse every enabled TLS mode plus missing/regular-file paths before any
driver dial. These are deterministic option/refusal tests, not new live TLS or
SSH acceptance evidence.

Export writer tests simulate three-byte writes, interrupted writes and destination
I/O failures. All six text formats must finish short writes without byte loss;
all seven formats, including XLSX, must propagate write failures. These injected
writer failures do not simulate filesystem exhaustion or a broken network stream.

The first parser mutation run intentionally remains failed at
`target/quality/20260927-b3-parameter-mutants/mutants.out/outcomes.json`:
16 caught, one survivor, five timeouts and two unviable mutations. The survivor
removed the Boolean false arm; a new truth-table regression covers accepted
true/false spellings and invalid text. Extractor tests now call the parser on a
worker with a two-second receive deadline, turning nontermination into a test
failure rather than waiting for cargo-mutants to kill the suite. Production
parsing is unchanged. Compilation failures are unviable, not caught mutations.

The installed UI run reused the release binary from checkpoint `39198f1` because
this change only adds tests and documentation. Its SHA-256 is
`010fbec4d00d9cd391fa982e54ab038ac18a16d43755369c6afc28b31555cd30`.

The corrected run at
`target/quality/20260927-b3-parameter-mutants-corrected/mutants.out/outcomes.json`
caught all 22 compilable mutations, with two unviable, no survivors and no timeouts.
No mutation was excluded. The initial combined full/value/UI/harness run passed at
`target/quality/20260927T100452073699Z-layers/report.json`; its eight-driver report
is `target/quality/20260927T100713477391Z-values/report.json`. All 24 installed UI
scenarios passed with 24 JSON/stderr pairs in
`target/quality/20260927-b3-parameter-ui/`. Thirty-five Python harness tests passed.

After the Boolean and bounded-parser refinements, the final full/value/harness
rerun passed at `target/quality/20260927T101253832016Z-layers/report.json`.
All 11 value suites passed again at
`target/quality/20260927T101514358887Z-values/report.json`, including 21 core
contracts. Hosted CI and B4–B6 acceptance remain separate; B3 stays open for the
remaining native types and consumer parity.

## XML text consumer checkpoint, 2026-09-27

Two core regressions failed before the fix: literal carriage returns were not
protected from parser normalization, and XML-illegal text was silently replaced
with U+FFFD while export reported success. An installed-app reproducer against
the previous binary also failed after parsing its real exported file; evidence
is retained under `target/quality/20260927-b3-xml-before/`.

XML export now writes CR as `&#13;`, preserving standalone CR and CRLF alongside
LF, tabs, literal entity-looking text and Unicode. Unsupported XML 1.0 characters
are refused with the code point and one-based data row/column, with a JSON export
suggestion. Existing destination bytes survive the refusal, including when an
earlier row has already been written to the temporary file. Tests cover NUL,
controls, U+FFFE/U+FFFF, legal Unicode range boundaries, NULL and empty text.
The behavior follows [XML line-ending handling](https://www.w3.org/TR/xml/#sec-line-ends)
and [legal XML characters](https://www.w3.org/TR/xml/#charsets).

Two default installed-GTK scenarios exercise XML selection and the save chooser,
then parse the output or require the visible refusal. Four Python tests validate
the independent oracle and scenario registration, including deliberately
normalized line endings and an empty-text/NULL corruption. The existing workbook
scenarios share the named export-format keyboard helper. XML column-name
sanitization and type annotation are unchanged; this text checkpoint does not
establish reversible arbitrary column labels or complete typed XML import.

Scoped mutation evidence is
`target/quality/20260927-b3-xml-mutants/mutants.out/outcomes.json`: 15 caught,
one unviable, no survivors or timeouts across the row writer, text escaping and
legal-character predicate. The compilation failure is not counted as a catch.
The shared value report at `target/quality/20260927T102839954853Z-values/report.json`
passed all 11 suites, including 24 core contracts and all eight drivers.

Final local full/value/UI/harness report:
`target/quality/20260927T102554255832Z-layers/report.json`, all layers passed.
All 26 installed release-build UI scenarios passed with 26 JSON/stderr pairs at
`target/quality/20260927-b3-xml-ui/`; all 39 Python harness tests passed.
These are X11/AT-SPI and local fixture results. Hosted CI, installed Wayland and
package acceptance remain separate; B3 stays open for remaining native types
and consumer parity before B4–B6 acceptance.

## DuckDB native temporal and enum checkpoint

The native decoder previously exposed `date32:-1`, timestamp unit counters, interval descriptions and Arrow collection debug output as ordinary text. The first new live embedded-engine regression failed when SQL re-import tried to parse `date32:-1` as a date.

Dates and times now use shared typed values where representable. Timestamp seconds, milliseconds, microseconds and nanoseconds are split with Euclidean division so negative fractional epochs retain their exact fraction. Arrow timezone metadata selects the UTC instant variant. Enum dictionary labels preserve empty text, literal NULL text, Unicode and SQL NULL. Date infinities, BC dates and years above 9999 use DuckDB-compatible text; 24:00:00 remains distinct from midnight.

The enum contract also round-trips the empty, `NULL`, and Unicode labels through
SQL literals and typed parameters. Each server result retains an ENUM native
type and exact VARCHAR label; the literal label `NULL` remains distinct from
SQL NULL.

The integration corpus checks server-rendered source values against both parameter rebinding and generated SQL literals, plus independent JSON expectations for nanosecond timestamps and microsecond times. It includes nulls for every temporal family. Decoder unit tests cover all four units, negative remainders, end-of-day boundaries and arithmetic overflow.

Mixed month/day/microsecond intervals now preserve DuckDB's native month, day and nanosecond carrier fields as exact text with an explicit microsecond unit. A live embedded-engine contract checks `typeof`, DuckDB's `VARCHAR` representation and independent `date_part` component oracles, then re-imports through both a generated SQL literal and an explicitly cast bound parameter. DuckDB column metadata now exposes simple and composite primary keys from `duckdb_constraints()`, with an independent catalog oracle. A separate app-parser contract sends edited text through the keyed-update builder and verifies the saved native INTERVAL type and signed month/day/microsecond components. Intervals with sub-microsecond carrier precision remain explicitly undecodable. A MAP containing a UHUGEINT above `u64::MAX` and explicit NULL has exact native `typeof` and `VARCHAR` oracles; LIST, fixed ARRAY, STRUCT and UNION have exact native type and JSON rendering oracles. The driver, SQL-literal and parameter consumers explicitly refuse all these collection kinds. The `UHUGEINT[]` case has a native `typeof` and exact `VARCHAR` oracle for `18446744073709551616`; it is explicitly undecodable, and SQL literal and parameter consumers refuse it. Other interval boundaries, installed GTK acceptance and additional nested collection combinations remain open. At this checkpoint, dates outside the shared calendar range and finite timestamps outside years 1–9999 were explicitly undecodable; the October 3 follow-up below now covers named extended DATE/TIMESTAMP/TIMESTAMPTZ values. This is not full native-type, arbitrary-precision editing, MCP or release acceptance.

The interval boundary contract now covers `i32::MIN`/`i32::MAX` months and days,
plus the largest positive and negative whole-microsecond values that fit the
driver's signed nanosecond carrier. Independent `typeof`, `VARCHAR`, and
`date_part` assertions account for DuckDB normalizing months into years and
microseconds into clock fields. Both extremes round-trip through generated SQL
and explicitly cast bound parameters. Other mixed-sign combinations and the
installed GTK edit path remain open.

```sh
rtk cargo test --locked -p tablepro-driver-duckdb --test integration value_contract_interval_component_extremes_round_trip_as_exact_text -- --exact --test-threads=1
```

The focused embedded-engine contract passed.

The DuckDB decoder mutation pass initially found a surviving `UBigInt` signed-boundary comparison. Unit assertions now pin `i64::MAX` to `Value::Int` and `i64::MAX + 1` to exact decimal text. The final scoped run caught 11/12 mutants, with one unviable whole-function replacement and no survivors or timeouts: `target/quality/20260929-duckdb-interval-mutants-final/mutants.out/outcomes.json`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_interval_components_round_trip_as_exact_text -- --exact --test-threads=1
```

The local embedded-engine contract passed.

Sub-microsecond TIME and TIMESTAMP values, plus every `TimestampTz`, are sent
through DuckDB parameters as exact VARCHAR values because the bundled client has
no lossless native bind type for these cases. An unignored integration contract
checks `typeof(?)` and exact echoed text for a nanosecond TIME, a pre-epoch
nanosecond TIMESTAMP, and a nine-digit offset-origin TIMESTAMPTZ. It confirms
transport preservation and the UTC instant, not native typed binding; callers
must cast explicitly when using these text parameters in typed expressions.

A companion direct-binding contract uses the pinned `duckdb` crate's own
`Value::Time64(Nanosecond, ...)` and `Value::Timestamp(Nanosecond, ...)`
parameters. DuckDB reports native TIME/TIMESTAMP types but returns only the
first six fractional digits (`12:34:56.123456` and
`2026-09-27 12:34:56.123456`), proving the crate's nanoseconds-to-microseconds
conversion is lossy. This is why the adapter retains exact VARCHAR fallback.
The focused regression passed:

```sh
rtk cargo test --locked -p tablepro-driver-duckdb --test integration pinned_duckdb_binding_api_truncates_nanosecond_temporals_to_microseconds -- --exact --test-threads=1
```

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_submicro_temporals_bind_as_exact_text -- --exact --test-threads=1
```

The focused test and the full DuckDB integration suite passed (16 tests).

### DuckDB TIMESTAMPTZ grid-edit precision boundary

A failing-first app parser contract showed that a nine-digit
`TimestampTz` edit was accepted for DuckDB `TIMESTAMP WITH TIME ZONE`. The
independent embedded-engine oracle binds the exact value as text and casts it
to native TIMESTAMPTZ; `epoch_us` proves the server drops the non-microsecond
digits. The app now refuses values whose nanoseconds are not divisible by
1,000 before the keyed update is built. It still accepts ordinary microsecond
precision and nine-digit spellings with three trailing zeroes. An app-level
DuckDB grid contract uses actual column metadata, verifies refusal leaves the
stored epoch unchanged, then saves an offset-origin, microsecond-aligned edit
and checks the resulting native type and exact UTC epoch.

The same precision check was missing for DuckDB `TIME` and `TIMESTAMP` grid
edits. A new failing-first app parser regression reproduced acceptance of
nine-digit fractions for these microsecond columns. The keyed-edit test also
checks native `TIMESTAMP_S` and `TIMESTAMP_MS` casts, proving those discard
unsupported fractional digits at their declared precision. It then verifies the
parser refuses all four edits and leaves existing native values unchanged.
Precision-aware parsing still accepts exact microsecond and millisecond values;
nanosecond `TIMESTAMP_NS` values remain exact, while `TIME_NS` stays as text.

The strict GTK + DuckDB runner passed all 156 selected tests across 11 suites
with no missing suites at dirty revision `fde1128`:
`target/quality/20260930T182412713329Z-values/report.json`. The DuckDB app
parser/grid cases live in `crates/app/tests/support/duckdb_temporal_edit_contract.rs`
to keep the shared parser contract below the hosted 1,200-line file-size limit.
A scoped
`cargo-mutants` pass generated 13 changes to `parse_duckdb_temporal_input`; the
app library tests caught 12, with 0 missed, 0 timeouts and 1 unviable in
`target/quality/20260930-duckdb-temporal-grid-mutants-final/mutants.out/outcomes.json`.

The scoped mutation report caught 9 of 10 generated changes to this precision
guard; one whole-function replacement was unviable, with no survivors or
timeouts:
`target/quality/20260929-duckdb-timestamptz-guard-mutants-final/mutants.out/outcomes.json`.

The earlier app-parser mutation run had four apparent survivors because its test
filter selected only the DuckDB case while `parse_input_for_driver` also routes
PostgreSQL numeric input. A corrected full app-library mutation run caught all
four viable changes; the fifth was an unviable whole-function replacement:
`target/quality/20260930-app-value-parser-cross-driver-mutants/mutants.out/outcomes.json`.

```sh
rtk cargo test -p tablepro-app --lib value_contract_duckdb_timestamptz_parser_refuses_submicro_edits
rtk cargo test -p tablepro-app --features duckdb --lib value_contract_duckdb_timestamptz_grid_edit_refuses_submicro_rounding
rtk cargo mutants --manifest-path crates/app/Cargo.toml --in-place --file crates/app/src/ui/browse_tab/value_parse.rs --re parse_input_for_driver --output target/quality/20260930-app-value-parser-cross-driver-mutants --no-config -- --lib
rtk proxy ./scripts/test-value-contracts.sh --gtk --duckdb
```

The strict combined run passed all 127 tests across 11 suites with no missing
suites and a clean checkout at `cdbb15b538656602a9fdd08f4e6626deb2553540`.
The report is `target/quality/20260929T194746719695Z-values/report.json`.

### DuckDB scalar HUGEINT consumer parity

The embedded DuckDB contract checks signed `HUGEINT` minimum/maximum and
`UHUGEINT` maximum. Native `typeof` and `VARCHAR` projections confirm exact
decimal digits; result decoding, SQL-literal re-import and text-bound casts
preserve the same values. These scalar contracts are separate from the
explicitly undecodable nested `UHUGEINT[]` case.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_scalar_hugeints_preserve_exact_text_across_consumers -- --exact --test-threads=1
```

The focused embedded DuckDB test passed.

Run locally:

```sh
cargo test --locked -p tablepro-driver-duckdb --lib --test integration
./scripts/test-value-contracts.sh --gtk --duckdb
```

The strict value runner automatically includes the new integration cases. Native decoder unit cases also run in the optional DuckDB crate test job. Protocol references: [DuckDB timestamps](https://duckdb.org/docs/current/sql/data_types/timestamp) and [interval basis units](https://duckdb.org/docs/current/sql/data_types/interval).

Validation: the DuckDB crate passed 16 tests (12 unit, four integration). Full local checks, all 11 selected value suites and the Python harness passed in `target/quality/20260927T104559674200Z-layers/report.json`; detailed value evidence is `target/quality/20260927T104731515648Z-values/report.json`. The combined value build reused 742 artifacts and rebuilt only the DuckDB package. Installed UI/Wayland and package acceptance were not rerun for this driver-only checkpoint.

Optional-driver Clippy (`cargo clippy --locked -p tablepro-driver-duckdb --all-targets -- -D warnings`) also passed. Its first run selected a separate native build fingerprint and rebuilt the bundled C++ library; this differs from the cached combined value runner above. Reuse a consistent command/feature graph for routine value checks.

Scoped mutation evidence: `target/quality/20260927-b3-duckdb-temporal-mutants/mutants.out/outcomes.json` records all 31 generated mutations in `temporal.rs`: 28 caught, three unviable, zero survivors and zero timeouts. Both the crate unit tests and integration suite ran for each viable mutation; compile failures are not counted as catches. Command:

```sh
mkdir -p target/mutation-tmp
TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-driver-duckdb --file crates/drivers/duckdb/src/temporal.rs --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/duckdb-temporal-mutants -- --lib --test integration
```

## PostgreSQL interval fields, temporal arrays and infinities

The native interval regression first failed when `i64::MIN` microseconds became `-2562047788:00:54.775808`, which PostgreSQL could not parse back. Large hour fields now use an exact decimal-seconds representation. Any negative interval component triggers explicit signs on positive components, avoiding IntervalStyle-dependent reinterpretation. The corpus constructs expected months/days/microseconds wire bytes itself and checks the source fixture before comparing decoder results. It covers 59 boundary/generated cases across postgres, sql_standard, postgres_verbose and iso_8601 styles (236 combinations), pooled/session parity, SQL literals, typed casts of bound text and JSON text.

A second reproducer returned Undecodable for DATE infinity and date arrays. The driver now recognizes PostgreSQL infinity sentinels and decodes date, time, timetz, timestamp, timestamptz and interval array elements. Existing array dimension/lower-bound and size guards remain. Native array_send equality checks cover eras, year 10000, microseconds, end-of-day time, second-resolution offsets, DST-distinct instants, infinities, NULL elements and multidimensional bounds. SQL INSERT and bound parameter re-imports are included; a session in Asia/Kathmandu verifies that timestamp array imports preserve UTC instants.

New unit contracts check temporal element lengths, out-of-range payloads, empty/null arrays, infinity signs, era formatting and interval extremes. A real PostgreSQL DATE at year 1,000,000 remains within the server's finite range but exceeds chrono's shared calendar: the driver returns `Undecodable("DATE")`, while an independent `date::text` column remains exactly `1000000-01-01`. The app date parser rejects that input, and SQL literal rendering and parameter binding refuse the undecodable marker. A TIMESTAMP at PostgreSQL's upper finite bound, `294276-12-31 23:59:59.999999`, is also accepted by the server but returned as `Undecodable("TIMESTAMP")`; its independent `timestamp::text` value is exact, and the app parser, SQL literal renderer and parameter binder refuse it. Full finite temporal support beyond chrono's range, unsupported element types and broader consumer parity remain open. These changes do not prove complete native-type support for PostgreSQL or the other drivers.

Run `cargo test --locked -p tablepro-driver-postgres --lib value_contract`, then `cargo test --locked -p tablepro-driver-postgres --test integration value_contract_dates_preserve_eras_large_years_and_instants -- --include-ignored --exact --test-threads=1` with Docker available. The combined strict value runner discovers all seven PostgreSQL server contracts. Updated fixture declarations are recorded in [ignored tests](../ignored-tests.md).

Reference: [PostgreSQL interval input and storage](https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-INTERVAL-INPUT). The strategy for extending these proofs across drivers is in [type contracts](../type-contract-strategy.md).

Mutation evidence: `target/quality/20260927-b3-pg-native-mutants/mutants.out/outcomes.json` records 74 selected mutations: 73 caught, one unviable, zero survivors and zero timeouts. This measurement ran value-contract unit tests for interval decoding/formatting, temporal-array dispatch/text and scalar temporal decoding; it was not a full-workspace mutation run. The separate PostgreSQL 16 fixture run supplies real-server evidence. Reproduce from the Linux workspace:

```sh
mkdir -p target/mutation-tmp
TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-driver-postgres --file crates/drivers/postgres/src/temporal.rs --file crates/drivers/postgres/src/array.rs --file crates/drivers/postgres/src/decode.rs --re 'decode_interval|format_interval|push_counted|decode_temporal|temporal_element|array_text' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/pg-native-mutants -- --lib value_contract
```

The first full-gate attempts remain recorded in `20260927T110823517670Z-layers/report.json` (stale ignored-test inventory) and `20260927T110938605682Z-layers/report.json` (file-size guard). Both are under `target/quality/`. The inventory was regenerated and scalar temporal decoding moved into the existing temporal module without raising a guardrail baseline. The subsequent `20260927T111058478564Z-layers/report.json` passed full, values and harness; its value report is `20260927T111306775227Z-values/report.json` with all 11 suites and seven PostgreSQL contracts passing.

Final clean-source validation after mutation testing passed full, values and harness in `target/quality/20260927T111941420743Z-layers/report.json`. All 11 selected value suites passed in `target/quality/20260927T112138445468Z-values/report.json`; compilation reused 745 artifacts, rebuilt zero packages and took 0.592 seconds. Installed UI/Wayland and package acceptance were not rerun for this driver checkpoint.

## MySQL native TIME, zero-date and YEAR checkpoint

The reproducer ran against MySQL 8 with a permissive `sql_mode`. Before the fix, `-01:00:00` read back as `01:00:00`. Zero DATE, DATETIME and TIMESTAMP values read as NULL, because sqlx reports an all-zero binary value as NULL. TIME outside one day, dates with zero parts and every YEAR value were undecodable. Times of day remain `Time`. Negative or extended times, zero dates and dates with zero parts are now exact text, and YEAR is an integer. sqlx 0.9 also reports the TIME sign inverted, so the driver reads the sign field directly.

The test compares every value with an independent expected value. It then writes the rows back through bound parameters and SQL INSERT export, and the server confirms all six rows match with `<=>`. Scoped cargo-mutants on `crates/drivers/mysql/src/temporal.rs`: 16 mutants, 13 caught, 3 unviable, zero survivors and zero timeouts, using the recipe above with `-- --lib --test integration -- --include-ignored calendar_fields native_time_zero`.

MySQL `TIMESTAMP` values are exact only while the server session is UTC because MySQL returns a session-local wall time and sqlx decodes it as UTC. Driver-owned pool connections set `time_zone = '+00:00'` when created and reset it before each checkout. Dedicated sessions start in UTC; if a session later uses another time zone, non-NULL `TIMESTAMP` cells are returned as undecodable rather than as a wrong instant. A Docker regression first reproduced the mismatch at `+05:45`, then verified the independent session-local text and Unix-epoch microseconds while checking the refusal marker. The same regression changes a pooled connection to `+05:45` and confirms the next checkout still returns the exact UTC instant. The existing zero-date temporal round-trip continues to verify UTC pooled decoding. Run `cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mysql --test integration session_non_utc_time_zone_refuses_mysql_timestamp_instant -- --include-ignored --exact --test-threads=1` and `cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mysql --test integration native_time_zero_date_and_year_values_survive_reads_parameters_and_exports -- --include-ignored --exact --test-threads=1` with Docker available.

Subsequent B3 coverage verifies BIT(1..64), ENUM/SET labels and spatial bytes;
bounded BIT edits survive a driver update, while spatial and too-wide BIT values
remain read-only. Text exports also run with default,
`NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES`, and combined session modes.
Backslash-bearing column comments are explicitly refused. A dedicated-session
Docker regression creates the same DDL under default mode and
`NO_BACKSLASH_ESCAPES`; the server stores one backslash versus two, confirming
that mode-independent output needs session-aware DDL execution. Run it with
`cargo test --locked -p tablepro-driver-mysql --test integration mysql_column_comment_backslash_literals_depend_on_sql_mode -- --include-ignored --exact --test-threads=1`.
I tested reusing the SQL export's `_utf8mb4 X'…'` literal in a generated
`COMMENT` clause; the MySQL server rejects it with syntax error 42000. The DDL
builder therefore continues to refuse backslash comments safely. Supporting
them requires controlled session-mode handling around DDL, including reliable
restoration after errors; ordinary mode-independent string literals are not
accepted by this COMMENT grammar.
Session time-zone and stricter SQL-mode matrices, installed-app-to-MySQL grid
acceptance and broader consumer parity remain open.


### MySQL strict zero-date SQL modes (2026-10-04)

Dedicated sessions on MySQL 8 and MariaDB 11 enable
`STRICT_TRANS_TABLES`, `NO_ZERO_DATE` and `NO_ZERO_IN_DATE`, then verify that
both `0000-00-00` and `2024-00-15` are refused with SQLSTATE `22007`. The
failed inserts leave the destination empty; a valid date persists with exact
native and text values. The existing permissive-mode zero/partial-date
read, bound-write and SQL-literal round-trip contract continues to pass. Both
strict-mode cases and all nine MySQL/MariaDB value-contract tests pass, along
with strict Clippy and formatting. Other modes and consumer
paths remain open. See the [native evidence](../evidence/mysql-strict-zero-date-results-2026-10-04/manifest.json).

### MySQL/MariaDB fractional TIME mode semantics (2026-10-04)

On MySQL 8.1 and MariaDB 11, a `TIME(3)` destination receiving
`12:34:56.789900` with the fractional
rounding/truncation modes absent stores as `.790` on MySQL and `.789` on
MariaDB. Enabling `TIME_TRUNCATE_FRACTIONAL` on MySQL changes the stored value to `.789`;
enabling `TIME_ROUND_FRACTIONAL` on MariaDB changes it to `.790`. Each case
checks bound parameters and generated SQL literals independently, then checks
the returned `Value::Time`, native text and `MICROSECOND()` against stored
results. The test sets an empty session `sql_mode` for the baseline, so this
records the engines' mode-absent temporal behavior rather than every vendor's
unmodified server mode. See the [native evidence](../evidence/mysql-fractional-time-mode-results-2026-10-04/manifest.json),
[MySQL SQL mode reference](https://dev.mysql.com/doc/refman/8.0/en/sql-mode.html)
and [MariaDB SQL mode reference](https://mariadb.com/docs/server/server-management/variables-and-modes/sql_mode).
Other temporal types, precisions, consumers and installed typed edits remain
open.

### MySQL/MariaDB exact-half fractional TIME boundary (2026-10-04)

The native cases insert `12:34:56.789500` into `TIME(3)`, exactly halfway
between `.789` and `.790`. MySQL rounds to `.790` with
`TIME_TRUNCATE_FRACTIONAL` absent and truncates to `.789` with that mode set;
MariaDB truncates to `.789` with `TIME_ROUND_FRACTIONAL` absent and rounds to
`.790` with it set. Both bound and generated-literal paths assert the returned
time, cast text and native `MICROSECOND()` value. See the [native evidence](../evidence/mysql-fractional-time-tie-results-2026-10-04/manifest.json).

### MySQL/MariaDB exact-half DATETIME and TIMESTAMP boundaries (2026-10-04)

The native cases insert `2024-01-02 03:04:05.789500` into `DATETIME(3)` and
`TIMESTAMP(3)`. MySQL rounds to `.790` with `TIME_TRUNCATE_FRACTIONAL` absent
and truncates to `.789` with it enabled; MariaDB truncates to `.789` by default
and rounds to `.790` with `TIME_ROUND_FRACTIONAL` enabled. Both bound and
generated-literal paths assert the stored native value, cast text and
`MICROSECOND()` result. TIMESTAMP runs set the session timezone to UTC and
check epoch microseconds. See the [native evidence](../evidence/mysql-fractional-half-boundary-matrix-results-2026-10-04/manifest.json).

### MySQL/MariaDB TIME fractional precision matrix (2026-10-04)

The native cases insert `12:34:56.789956` into `TIME(0)` through `TIME(6)`.
MySQL's default rounds at each declared precision and
`TIME_TRUNCATE_FRACTIONAL` truncates; MariaDB's default truncates and
`TIME_ROUND_FRACTIONAL` rounds. Both bound and generated-literal paths assert
the returned `Value::Time`, cast text and `MICROSECOND()` result for every
precision. See the [native evidence](../evidence/mysql-time-precision-matrix-results-2026-10-04/manifest.json).

### MySQL/MariaDB DATETIME and TIMESTAMP fractional precision matrix (2026-10-04)

The native cases insert `2024-01-02 03:04:05.789956` into both
`DATETIME(0)` through `DATETIME(6)` and `TIMESTAMP(0)` through `TIMESTAMP(6)`.
MySQL rounds by default and truncates with `TIME_TRUNCATE_FRACTIONAL`; MariaDB
truncates by default and rounds with `TIME_ROUND_FRACTIONAL`. Bound and
generated-literal paths assert native values, cast text and `MICROSECOND()`;
TIMESTAMP checks also pin the UTC epoch microseconds. See the
[native evidence](../evidence/mysql-datetime-timestamp-precision-matrix-results-2026-10-04/manifest.json).

### MySQL/MariaDB fractional DATETIME mode semantics (2026-10-04)

The paired Docker cases apply the same mode matrix to a `DATETIME(3)`
destination and input `2024-01-02 03:04:05.789900`. With the fractional modes
absent, MySQL 8.1 stores `.790` and MariaDB 11 stores `.789`;
`TIME_TRUNCATE_FRACTIONAL` truncates on MySQL, while
`TIME_ROUND_FRACTIONAL` rounds on MariaDB. Bound parameters and generated SQL
literals are checked separately against returned `Value::DateTime`, cast text,
and `MICROSECOND()`. As in the TIME cases, the tests clear session `sql_mode`
for the baseline. Other temporal types, precisions and consumer paths remain
open; see the [native evidence](../evidence/mysql-fractional-datetime-mode-results-2026-10-04/manifest.json).

### MySQL/MariaDB fractional TIMESTAMP mode semantics (2026-10-04)

The paired Docker cases insert `2024-01-02 03:04:05.789900` into
`TIMESTAMP(3)` with the dedicated session timezone set to UTC. With the
fractional modes absent, MySQL 8.1 stores `.790` and MariaDB 11 stores `.789`;
`TIME_TRUNCATE_FRACTIONAL` truncates on MySQL, while
`TIME_ROUND_FRACTIONAL` rounds on MariaDB. Bound parameters and generated SQL
literals are checked against returned `Value::TimestampTz`, UTC cast text,
`MICROSECOND()`, and `UNIX_TIMESTAMP()` epoch microseconds. The session
`sql_mode` is cleared for the baseline. Other temporal precisions and consumer
paths remain open; see the [native evidence](../evidence/mysql-fractional-timestamp-mode-results-2026-10-04/manifest.json).

### MySQL/MariaDB ENUM and SET consumers across SQL modes (2026-10-04)

MySQL and MariaDB replay SQL export files and import typed CSV containing six
rows spanning ENUM and SET under the default mode, `NO_BACKSLASH_ESCAPES`,
`ANSI_QUOTES`, both modes together, `STRICT_TRANS_TABLES`, and strict mode with
`NO_BACKSLASH_ESCAPES`. Values include apostrophe and
backslash labels, multiple selected SET members, literal `NULL`, the empty
SET, and SQL NULL. Typed CSV uses an explicit collision-free null marker so
the empty SET stays distinct from SQL NULL. Each mode checks native ENUM
ordinals, SET masks, label bytes and both copied tables against the source.
JSON preserves every value. XML, HTML and Markdown escape markup-shaped ENUM
and SET labels in all eight modes, including STRICT_ALL_TABLES with and without NO_BACKSLASH_ESCAPES. XLSX refuses the empty SET text and leaves a
pre-existing destination unchanged. Both focused Docker tests, strict Clippy
and formatting pass. SQL modes beyond these eight combinations and other enum/set
consumers remain open; see the [native evidence](../evidence/mysql-enum-sql-mode-results-2026-10-04/manifest.json).

The app edit path now validates ENUM labels and SET members against MySQL's
declared `column_type` before binding. A parser-to-keyed-edit contract preserves
an apostrophe label and a multi-member backslash SET across eight modes, including
`STRICT_TRANS_TABLES` and `STRICT_ALL_TABLES` alone and combined with `NO_BACKSLASH_ESCAPES`, with
native ordinals, masks, bytes and sibling identity. Blank input remains SQL
NULL; typing `''` explicitly selects an empty ENUM label or an empty SET, and
the native oracle distinguishes those values from SQL NULL. A separate permissive-mode
control demonstrates why the guard is required: MySQL otherwise turns an
unknown ENUM label into ordinal zero and silently drops an unknown SET member.
The control runs inside a transaction and rolls back. The app library suite,
strict Clippy, focused parser test and MySQL 8 Docker test passed. A matching
MariaDB 11 app edit now checks all eight modes, native label bytes and SET masks,
invalid-value refusal and sibling preservation. It also distinguishes blank SQL
NULL from explicit `''` empty ENUM and SET values against native ordinals/masks.
Both engine paths also key-edit the declared literal label `NULL` and verify its
non-NULL ordinal/bytes separately from the SQL NULL row. Additional SQL modes
remain open; see the
[grid evidence](../evidence/mysql-enum-set-grid-edit-results-2026-10-04/manifest.json).

### MySQL/MariaDB ENUM and SET strict ANSI_QUOTES combinations (2026-10-04)

The file-consumer and app keyed-edit matrices add four configurations: each of
`STRICT_TRANS_TABLES` and `STRICT_ALL_TABLES`, combined with `ANSI_QUOTES`, with
and without `NO_BACKSLASH_ESCAPES`. The expanded twelve-mode tests pass on
MySQL 8.1 and MariaDB 11. Native ENUM ordinals, SET masks, exact label bytes,
invalid-value refusal and untouched siblings remain asserted. Other SQL modes
and session settings remain open. See the [file-consumer evidence](../evidence/mysql-enum-sql-mode-results-2026-10-04/manifest.json)
and [grid-edit evidence](../evidence/mysql-enum-set-grid-edit-results-2026-10-04/manifest.json).

### MySQL text and JSON export under ANSI_QUOTES, 2026-09-30

The existing MySQL and MariaDB SQL export round trip also runs with
`ANSI_QUOTES` alone and combined with `NO_BACKSLASH_ESCAPES`. It writes
backslash-sensitive text and JSON through generated SQL literals, then checks
source and destination bytes with server-side `HEX()` equality. Default and
`NO_BACKSLASH_ESCAPES` modes remain in the same matrix. All four mode settings
passed on both MySQL 8 and MariaDB 11; production code did not need a change.
The strict GTK + DuckDB value runner also passed 148 tests across all 11 suites
with no missing suites. Report:
`target/quality/20260930T152649001249Z-values/report.json` (`dirty: true`, based
on `f8efdae`).

```sh
rtk cargo test --locked -p tablepro-driver-mysql --test integration value_contracts::value_contract_text_exports_survive_with_and_without_backslash_escapes -- --include-ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mysql --test integration value_contracts::value_contract_mariadb_text_exports_survive_with_and_without_backslash_escapes -- --include-ignored --exact --test-threads=1
```

### MySQL BIT parser, keyed edit and server value contract

The app-level Docker contract reads the actual `bit(1)`, `bit(8)`, `bit(63)`
and `bit(64)` column metadata, parses edits with the grid input parser, builds
the keyed update and writes through the MySQL driver. A false BIT(1), value 170
in BIT(8), and `i64::MAX` in BIT(63) are compared with both decoded results and
MySQL `HEX()` output. A BIT(64) value with its high bit set remains exact bytes;
the parser refuses an edit above the shared signed integer range. GTK-level
tests separately keep such bytes and spatial cells read-only.

```sh
rtk cargo test -p tablepro-app --lib value_contract_mysql_bit_parser_edits_preserve_native_values -- --include-ignored --test-threads=1
```

The focused Docker contract passed. Installed-app interaction and other MySQL
session modes remain separate acceptance targets. The unignored parser contract
checks BIT(1), (2), (8), (63) and (64) widths, width-specific maxima, negative
input and the shared signed bound. The first mutation run found that the
existing Docker-only test was not selecting a pure parser test. After adding
the unignored contract, the follow-up mutation run caught all 11 remaining
mutants with no survivors or timeouts; evidence is
`target/quality/20260929-mysql-bit-parser-mutants/mutants.out/outcomes.json`.
The strict combined runner passed the app, all seven server drivers, SQLite,
DuckDB and MCP suites on commit `c1b393f8d`: all 123 selected contracts passed
with no missing suites. Evidence is
`20260929T164906704313Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260929T164906704313Z-values/report.json`).

```sh
rtk cargo test -p tablepro-app --lib value_contract_mysql_bit_parser_enforces_declared_width_and_safe_range -- --test-threads=1
rtk cargo mutants --in-place --dir . --package tablepro-app --file crates/app/src/ui/browse_tab/value_parse.rs --re 'parse_mysql_bit_value|mysql_bit_width' --test-tool cargo --timeout 30 --build-timeout 120 --iterate --output target/quality/20260929-mysql-bit-parser-mutants -- --lib mysql_bit
```

### MySQL signed and unsigned integer grid parser, 2026-09-30

The failing-first parser contract found that unsigned metadata such as
`tinyint unsigned` fell through to text parsing, allowing out-of-range digits
to reach permissive sessions. The parser now enforces signed/unsigned ranges
for TINYINT, SMALLINT, MEDIUMINT, INT and BIGINT, accepts MySQL display-width
metadata, preserves the existing `tinyint(1)` boolean convention, and keeps
`BIGINT UNSIGNED` values above `i64::MAX` as exact decimal text up to `u64::MAX`.
The unit matrix checks both boundaries and one-past-range inputs for all widths.
The initial mutation report
`target/quality/20260930-mysql-integer-parser-mutants/mutants.out/outcomes.json`
showed an untested signed INT branch and redundant signed BIGINT special case.

A Docker-backed app contract sets `sql_mode = ''` and independently confirms
that MySQL clamps an invalid `TINYINT UNSIGNED` value of 256 to 255. The parser
refuses that value before the keyed update, while a valid edit stores 255 and
`18446744073709551615` exactly. A second row remains unchanged. The focused
parser test and native-server edit passed. The first scoped mutation run found
the missing signed INT boundaries plus a redundant signed BIGINT arm; the
regression now catches signed INT mutations and the duplicate BIGINT special
case was removed. The final 18-mutant run caught 17, had one compile-time
unviable replacement, and no survivors or timeouts:
`target/quality/20260930-mysql-integer-parser-mutants-final2/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-app value_contract_mysql_integer_parser_enforces_signed_and_unsigned_widths
rtk cargo test --locked -p tablepro-app value_contract_mysql_unsigned_integer_grid_edits_refuse_coercion_and_preserve_u64 -- --include-ignored --test-threads=1
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-app --file crates/app/src/ui/browse_tab/value_parse.rs --re 'parse_mysql_integer_input' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260930-mysql-integer-parser-mutants-final2 -- --lib -- --test-threads=1
```

### MySQL spatial bytes in the GTK grid

The isolated GTK widget contract binds `geometry`, `point` and `multipolygon`
columns containing spatial byte payloads. Each appears as the expected
`<9 bytes>` read-only label, the grid creates no editable `CellEditor`, and
binding the cells emits no pending edit. The widgets layer passed with this
test registered in the isolated-test inventory at clean commit
`2db9f59dc0b1be614440e941baa889f4036bcfb2`; report:
`target/quality/20260929T190108119267Z-layers/report.json`. Scoped mutation testing of the
bytes-specific editability guard caught both generated mutations. A broader
mutation pass also exercised primary-key, generated-column, auto-increment and
`mixed` guards; it left five stricter-read-only survivors because this test only
asserted the spatial refusal. The unignored positive control
`ordinary_text_columns_remain_editable` now verifies regular VARCHAR columns
remain editable, alongside the existing unit contract that spatial values stay
read-only. The full app-library mutation rerun caught all 11 generated
editability mutations, with no survivors, timeouts or unviable mutants. Evidence:
`target/quality/20260929-mysql-spatial-ui-guard-mutants/mutants.out/outcomes.json`
`target/quality/20260929-mysql-spatial-ui-mutants/mutants.out/outcomes.json`,
and `target/quality/20260929-grid-editability-positive-control-mutants-final/mutants.out/outcomes.json`.
The strict runner passed 131 selected contracts on clean source
`70206f6fb9a5ce9901ffe4552743e63730100fe0`, with no missing suites:
`target/quality/20260929T214023821465Z-values/report.json` (`dirty: false`).
Installed-app acceptance and server-backed grid interaction remain open.

```sh
rtk proxy python3 scripts/run-test-layer.py widgets
rtk cargo test -p tablepro-app --lib ordinary_text_columns_remain_editable
rtk cargo test -p tablepro-app --lib mysql_bit_and_spatial_cells_follow_their_decoded_value_contract
rtk mkdir -p target/mutation-tmp-20260929-grid-editability
TMPDIR=$PWD/target/mutation-tmp-20260929-grid-editability CARGO_TARGET_DIR=$PWD/target rtk cargo mutants --dir . --package tablepro-app --file crates/app/src/ui/grid/presentation.rs --re 'column_is_editable' --test-tool cargo --timeout 60 --build-timeout 180 --output target/quality/20260929-grid-editability-positive-control-mutants-final -- --lib
```

## SQLite dynamic storage-class checkpoint

A new file-backed regression starts a `NUMERIC` column with TEXT, BLOB and NULL
values, then exercises bound edits that transition through REAL, BLOB, TEXT and
INTEGER storage classes. The test checks both SQLite's independent `typeof`
result and TablePro's decoded value. It then exports the edited rows as SQL
INSERT literals, re-imports into a second `NUMERIC` table and requires the same
storage classes and values. This closes the driver-level edit/SQL re-import
case. A policy-guarded CSV import test also covers legal text and numeric values
in INTEGER, REAL and NUMERIC affinity columns. A focused app contract now sends
`42.50` through the same column parser and keyed update builder used for grid
edits, then verifies `typeof(amount) = 'real'` and the returned `42.5` value.
Installed GTK/package acceptance across the storage-class matrix remains open.

The full SQLite integration suite passed all 21 tests. Run locally:

```sh
cargo test --locked -p tablepro-driver-sqlite --test integration
cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib sqlite_numeric_grid_edit_keeps_parser_and_affinity_behavior -- --test-threads=1
```

The mapped change-contract gate passed this exact app regression at
`target/quality/20260928T130321776497Z-change-contracts/report.json`.

The CSV import contract also checks the integer-form text `42`: SQLite stores
it as INTEGER in INTEGER and NUMERIC columns, and as REAL in the REAL column.
Together with `42.50` and nonnumeric text, this pins the three storage outcomes
after policy-guarded import; all 7 CSV import integration tests passed. A core
unit contract checks that nonnumeric fallback applies only to SQLite for
INTEGER/REAL/NUMERIC columns; MySQL and SQL Server keep rejecting those inputs.
The complete CSV cell-parser mutation scope caught 9 of 12 generated mutants;
the remaining 3 were unviable, with no misses or timeouts. Evidence:
`target/quality/20260930-sqlite-affinity-fallback-mutants-all-cell-tests/mutants.out/outcomes.json`.

At clean source SHA `061180e5aab9787e5f5c818ecafb8ec4403b8acb`, the strict
combined value-contract runner passed 147 selected tests across all 11 suites,
with GTK and DuckDB enabled and no missing suites. The quick layer also passed
in 93.1 seconds with a clean worktree. Reports:
`20260930T141019789442Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T141019789442Z-values/report.json`)
and `20260930T141439236199Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T141439236199Z-layers/report.json`).

## MongoDB nested BSON and native boundary checkpoint

A decoder unit regression first failed for nested `Decimal128`, binary and date
values. The driver converted all three to their debug-display strings, losing the
Decimal128 type/precision, binary subtype and exact BSON date milliseconds. Generic
binary values remain `Value::Bytes` for editing. Nested documents/arrays and top-level
non-generic binary values use canonical MongoDB Extended JSON so BSON special types
and subtype metadata remain explicit.

The unit regressions check Decimal128's smallest exponent, largest finite value,
negative zero and scale; every BSON binary subtype, including legacy UUID, encrypted,
column, sensitive, vector, reserved and user-defined values; and dates at both ends
of the signed 64-bit millisecond range. A Docker-backed test checks real UUID and
user-defined subtype values. Top-level Decimal128
values remain exact text because the shared decimal type cannot represent this
range. Dates that cannot be rendered as RFC3339 use canonical Extended JSON with
the exact signed millisecond count. A Docker-backed MongoDB 7 test inserts these
native BSON values directly, reads them through the driver query path, and checks
the resulting value/type representation. Uncommon top-level BSON types now use
canonical Extended JSON instead of display text. Real-server JSON, CSV and XLSX
consumer checks preserve their markers. A Docker-backed grid edit regression
updates a nested document and array through the keyed row update path, then
checks the stored Decimal128, date, binary subtype and integer fields through
the native BSON client. App parser tests route MongoDB object, array and ObjectId
columns through JSON parsing. MongoDB 7 integration tests verify canonical
Extended JSON re-import and MCP browse output preserve nested BSON types.
They also check nested Int64 above 2^53, explicit nested null and Unicode across
driver results, JSON/CSV/XLSX output, import and MCP browse response. An
unignored codec unit regression converts canonical Extended JSON back to native
BSON for Timestamp, regex, JavaScript, code-with-scope, Symbol, ObjectId,
DbPointer, Undefined, MinKey and MaxKey; it complements the Docker-backed
grid-write cases without requiring a server. The same non-ignored test checks
mixed String/Decimal128 identity through the JSON renderer and CSV exporter. A
second non-ignored unit case builds metadata from a String sample, merges a later
Decimal128 page value, and checks that the merged column is `mixed` before that
value is decoded with its canonical BSON marker.
Top-level Timestamp, regex, MinKey, MaxKey, JavaScriptCode, JavaScriptCodeWithScope,
Symbol and DbPointer grid edits round-trip as native BSON. JavaScriptCode is
checked separately without scope; the CodeWithScope regression checks both
stored code and its Int64 scope value; the Symbol and DbPointer regressions read
back native BSON values through the MongoDB client. The mixed String/Decimal128
grid case is covered as a read-only refusal; exact editing remains unsupported.
The current native-server grid matrix covers Timestamp, regex, MinKey, MaxKey,
JavaScriptCode, JavaScriptCodeWithScope, Symbol, Undefined, DbPointer,
Decimal128, top-level ObjectId fields and in-range BSON DateTime edits. The
ObjectId contract keeps `_id` stable, performs a keyed update to the `reference`
field, checks the reloaded `$oid`, then uses an independent MongoDB client to
confirm native ObjectId values. The date contract routes the RFC3339 value shown
in a `date` cell through the driver-aware parser, rejects sub-millisecond input
without changing the row, and verifies a valid offset-origin edit against the
stored BSON millisecond epoch. Other top-level kinds without a named
server-backed edit and collection-wide heterogeneity outside the metadata sample
and returned page remained open at this September 30 checkpoint. The October 3
collection census follow-up below supersedes the latter status for the tested
fixture; scan cost and concurrent-write consistency remain open.

The focused ObjectId grid contract is:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration value_contracts::value_contract_object_id_grid_edit_preserves_native_bson -- --include-ignored --exact --test-threads=1
```

The focused MongoDB 7 test passed. The clean all-driver selected-contract run
at source tip `63d67fc915e95c87ffbd8c7f781b60ca56a65657` passed 129 tests across
11 suites with no missing suites; MongoDB selected all eight contracts,
including this case. Evidence:
`target/quality/20260929T202504448591Z-values/report.json`. This is selected
contract evidence, not a claim that every crate test or installed UI path ran.

### MongoDB BSON DateTime grid-edit precision

A failing-first parser contract showed the exact RFC3339 value displayed for a
MongoDB `date` column failed with `Invalid date. Use YYYY-MM-DD.` because the
shared parser classified BSON DateTime metadata as date-only. The app now parses
MongoDB RFC3339 date edits as UTC instants, retains offsets and milliseconds,
accepts extra fractional digits only when they are zero, and refuses
sub-millisecond precision before update construction. Date-only input and other
drivers retain their existing parser behavior.

An app-level MongoDB 7 contract seeds a native BSON date, reads its displayed
text, runs the app parser and keyed update builder, then verifies the native
millisecond epoch through an independent MongoDB client. It also checks that a
sub-millisecond edit leaves the original server value unchanged and that a
valid `+05:30` edit preserves the exact UTC instant.

```sh
rtk cargo test -p tablepro-app --lib value_contract_mongodb_date_parser_preserves_milliseconds_and_refuses_rounding
rtk cargo test -p tablepro-app --lib value_contract_mongodb_date_grid_edit_preserves_millisecond_instant -- --include-ignored --test-threads=1
```

The focused tests passed. Scoped mutation testing of the MongoDB date parser
caught 7 of 8 generated mutations; one default-return mutant was unviable at
compile time, with no misses or timeouts. Its first isolated baseline build hit
the `/tmp` quota before any mutant ran; rerunning with scratch under
`target/mutation-tmp-20260929` completed successfully. Evidence:
`target/quality/20260929-mongodb-date-parser-mutants-home/mutants.out/outcomes.json`.
The clean strict combined runner passed 131 selected contracts across 11 suites,
no missing suites, at source tip `93d60ea818fe7d4c283bb86440deb7cf2501fe29`.
Both new app contracts appear in the log:
`target/quality/20260929T204726972421Z-values/report.json` (`dirty: false`).

Focused local checks:

```sh
cargo test --locked -p tablepro-driver-mongodb --lib nested_bson_special_values_keep_their_extended_json_types
cargo test --locked -p tablepro-driver-mongodb --lib bson_decimal_and_date_extremes_remain_exact_outside_core_ranges
rtk cargo test --manifest-path linux/Cargo.toml --locked -p tablepro-driver-mongodb --lib uncommon_top_level_bson_kinds_keep_extended_json_type_markers
rtk cargo test --manifest-path linux/Cargo.toml --locked -p tablepro-driver-mongodb --lib mixed_scalar_bson_column_keeps_canonical_type_markers
rtk cargo test --manifest-path linux/Cargo.toml --locked -p tablepro-driver-mongodb --lib page_type_conflict_marks_column_mixed_before_decoding_late_values
cargo test --locked -p tablepro-driver-mongodb --test integration -- nested_bson_special_values_keep_exact_extended_json_types --include-ignored --test-threads=1
cargo test --locked -p tablepro-driver-mongodb --test integration a_nested_and_max_key_grid_edit_writes_extended_json_back_as_native_bson -- --include-ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mongodb --test integration value_contracts::value_contract_db_pointer_grid_edit_preserves_native_bson -- --include-ignored --exact --test-threads=1
```

Against the old decoder, the regression failed with
`Decimal128("...")`, `Binary(...)`, and `DateTime("...")` as JSON strings. Full
MongoDB unit and real-server suites passed (24 unit tests; eight integration
tests). Scoped mutation evidence at
`target/quality/20260927-b3-mongodb-native-mutants/mutants.out/outcomes.json`
records four generated mutations: three caught, one unviable whole-function
replacement (`Value` has no `Default`), and no survivors or timeouts. The failing
pre-fix regressions independently demonstrate test sensitivity. The real-server
test verifies nested Extended JSON through JSON export and parses generated CSV
back into fields to check that quoting preserves the nested object. It also
exports the actual query result as XLSX and checks Decimal128, date and binary
subtype markers in workbook strings. An MCP unit contract confirms BSON
Extended JSON is passed through without flattening; Mongo-backed MCP browse and
native BSON re-import checks now run in the integration suite. Top-level
Timestamp, regex, MinKey, MaxKey, JavaScriptCodeWithScope and Symbol grid edits
are covered; Docker assertions check native CodeWithScope code/scope and Symbol
types after edits. The JavaScriptCode and Undefined cases also verify native
BSON kinds after edits. Local regressions use a BSON
String and Decimal128 with identical text: the field is labeled `mixed`, and
the shared app grid editability gate refuses both values because the result
model previously mapped each scalar to the same `Value::Text`. The grid gate
still refuses editing mixed values. The fix now makes `document_to_row` encode
every value in a `mixed` BSON column as canonical Extended JSON: a BSON String
becomes a JSON string and Decimal128 retains its `$numberDecimal` marker. The
unignored codec unit test checks this distinction through JSON and CSV; the
Docker-backed regression also verifies JSON, CSV and XLSX exports from a real
query and confirms the native BSON values remain distinct in storage.
Browse and `find` metadata starts from a 50-document sample, then incorporates
the bounded documents actually returned on the page. A Docker regression puts
Decimal128 at offset 50 after 50 String values and verifies the returned page's
column is `mixed`; the returned Decimal128 cell carries canonical Extended JSON
while the shared grid gate keeps the column read-only. Heterogeneity outside
both the sample and returned page remains undetected. A separate Docker test
checks that identical BSON String/Decimal128 text remains type-distinct through
the JSON renderer, CSV writer and XLSX workbook:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration mixed_string_decimal128_exports_preserve_bson_kind -- --include-ignored --exact --test-threads=1
```

The contract first failed against the old decoder because CSV flattened both
values to the same text. After the fix, the focused test passed. The full MongoDB
unit suite passed (31 tests), and the Docker-backed integration suite passed (18
tests) on the current worktree. These are local results, not CI evidence. The
earlier MongoDB 7 query/export/import and MCP browse Docker tests passed with
large Int64, null and Unicode values added on 2026-09-28.

A separate homogeneous Decimal128 contract composes the default CSV exporter,
typed CSV parser, and keyed grid update. The decimal column metadata parses the
CSV cell as `Value::Decimal`; after the update, a native BSON read confirms the
field remains `Bson::Decimal128` with the exact original value. This covers a
typed same-schema round trip. The new mixed-column contract independently checks
Extended JSON identity through JSON, CSV and XLSX.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration decimal128_csv_round_trip_through_typed_grid_edit_keeps_native_bson -- --include-ignored --exact --test-threads=1
```

The focused MongoDB 7 Docker contract passed.

### Generic BSON binary grid editing, 2026-09-30

A native MongoDB 7 regression reads a top-level Generic-subtype binary field as
editable `Value::Bytes`, builds the keyed update, and writes different bytes
including NUL and invalid UTF-8. A separate MongoDB client confirms both the
persisted bytes and Generic subtype; the driver then reads back the same byte
sequence. This confirms exact editing for this binary subtype without
converting it to display text or canonical JSON.

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --test integration value_contracts::value_contract_generic_binary_grid_edit_preserves_native_bson -- --ignored --exact --test-threads=1
```

The focused Docker test passed. Mutation testing of `value_to_bson` first found
ten viable survivors in the naive/UTC date millisecond-alignment guards. A unit
contract now checks exact millisecond bindings and refusal of one-nanosecond
sub-millisecond values for both variants; the rerun caught all 11 generated
mutants, with no misses, timeouts or unviable mutants:
`target/quality/20260930-mongodb-value-to-bson-mutants-final/mutants.out/outcomes.json`.

### MongoDB binary subtype grid matrix, 2026-09-30

A Docker-backed keyed-edit contract verifies Generic, Function, BinaryOld,
UUIDOld, UUID, MD5, Encrypted, Sensitive, Vector, Reserved `0a`, and
user-defined `80` subtype values against both canonical driver values and native
BSON subtype/byte oracles. Arbitrary bytes for Column subtype `07` are malformed
and MongoDB rejects them with `NonConformantBSON` (code 378). The test now gets
valid subtype-07 payloads directly from MongoDB time-series buckets: after
closing and reopening each bucket, MongoDB compresses its measurements into a
BSONColumn. The keyed grid edit replaces one valid server-generated column with
another; BookiE and an independent client both confirm exact subtype and payload
preservation. MongoDB's time-series compression description is in the
[server documentation](https://www.mongodb.com/docs/v7.0/core/timeseries/timeseries-compression/).

The opaque-subtype matrix and positive BSONColumn edit passed:

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --test integration value_contracts::value_contract_binary_subtypes_survive_native_grid_edits -- --include-ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mongodb --test integration value_contracts::value_contract_server_generated_bson_column_survives_grid_edit -- --include-ignored --exact --test-threads=1
```

### MongoDB UUID binary grid editing, 2026-09-30

The existing Generic-subtype edit did not prove subtype-04 UUID binary editing.
The native-server nested/special-value edit contract now changes a top-level
UUID binary field through the keyed update path. A MongoDB client independently
checks that subtype `Uuid` and all 16 bytes survive, while a driver query checks
the canonical Extended JSON value. The focused Docker integration test passed:

```sh
rtk cargo test --locked -p tablepro-driver-mongodb --test integration value_contracts::a_nested_and_max_key_grid_edit_writes_extended_json_back_as_native_bson -- --include-ignored --exact --test-threads=1
```

### MongoDB negative Decimal128 CSV formula marker

The default CSV exporter prefixes negative text cells with an apostrophe to
prevent spreadsheet formula execution. Before the fix, typed CSV import tried
to parse `'-123.45` directly as a decimal and returned `NotANumber`. The core
importer now removes that marker only when the destination column is Decimal
and the remaining cell parses as an exact `rust_decimal::Decimal`; ordinary
text retains the apostrophe. A MongoDB 7 contract exports a native Decimal128,
parses the default sanitized CSV against the `decimal` column metadata, applies
the imported value through a keyed grid update, and confirms the native BSON
value remains exactly Decimal128 `-123.45`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core --lib formula_marker_is_removed_from_negative_decimal_cells_only_for_decimal_columns
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration negative_decimal128_csv_formula_marker_round_trips_as_native_decimal128 -- --include-ignored --exact --test-threads=1
```

Both the focused core regression and MongoDB 7 Docker contract passed.

### MongoDB wide Decimal128 grid edit

A failing-first app parser contract showed that a valid 34-digit Decimal128
value was rejected as `Invalid decimal` because `rust_decimal` has a narrower
range. The MongoDB parser now keeps ordinary in-range decimals on the existing
`Value::Decimal` path and validates wider input with BSON Decimal128. Wider
values travel through the keyed update as canonical `$numberDecimal` Extended
JSON, preserving BSON type and digits. Inputs exceeding Decimal128 precision or
with invalid syntax are refused rather than rounded. The fallback is limited to
MongoDB `decimal` columns.

A MongoDB 7 app contract seeds `9.9900`, edits it to a 34-digit integer through
the app parser and keyed-update builder, then checks the row identity and exact
native `Bson::Decimal128` value through an independent client. Parser tests also
cover a 34-digit fraction, preserved `1.2300` scale, NaN and infinities, invalid
syntax, over-precision refusal, and unchanged MySQL behavior.

```sh
rtk cargo test -p tablepro-driver-mongodb --lib decimal128_edit_parser_preserves_native_precision_and_refuses_rounding
rtk cargo test -p tablepro-app --lib value_contract_mongodb_decimal128_parser_preserves_wide_precision
rtk cargo test -p tablepro-app --lib value_contract_mongodb_decimal128_grid_edit_preserves_wide_precision -- --include-ignored --test-threads=1
```

The three focused tests passed. Scoped mutation testing caught 4 of 5 app-parser
mutations; one generated default-return mutant was unviable at compile time.
Both BSON Decimal128 helper mutations were caught. The clean strict runner passed
133 selected tests across all 11 suites at source
`35d457fa488768a5204a26d785c90114073d4acd`, with no missing suites. Evidence:
`target/quality/20260929-mongodb-decimal-parser-mutants/mutants.out/outcomes.json`,
`target/quality/20260929-mongodb-decimal-driver-mutants/mutants.out/outcomes.json`,
and `target/quality/20260929T215946474345Z-values/report.json` (`dirty: false`).

Focused local results:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --lib mixed_scalar_bson_column_is_marked_and_values_remain_visible
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib mixed_bson_columns_are_read_only -- --test-threads=1
```

Both pass. The real-server contract is
`mixed_string_and_decimal128_columns_keep_values_and_refuse_lossy_edit_metadata`:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration mixed_string_and_decimal128_columns_keep_values_and_refuse_lossy_edit_metadata -- --include-ignored --exact --test-threads=1
```

Late page sampling is covered by
`browse_page_types_include_documents_after_the_metadata_sample`:

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration browse_page_types_include_documents_after_the_metadata_sample -- --include-ignored --exact --test-threads=1
```

### MongoDB BSON Undefined grid edit

A Docker-backed contract inserts native BSON `Undefined`, verifies the grid
metadata and canonical `{"$undefined":true}` value, applies the shared keyed
row update, then reads the row through both BookiE and the native BSON client.
The persisted value remains `Bson::Undefined`; it does not become null. The
focused MongoDB 7 test passed.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration value_contract_undefined_grid_edit_preserves_native_bson -- --include-ignored --exact --test-threads=1
```

### MongoDB JavaScriptCode grid edit

A BSON JavaScriptCode value is shown in the grid as its canonical `$code`
marker, edited through the shared keyed row update, and checked after reload.
The native MongoDB client confirms that the stored value remains
`Bson::JavaScriptCode` with the edited code string, rather than an ordinary
BSON string.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --test integration value_contract_javascript_code_grid_edit_preserves_native_bson -- --include-ignored --exact --test-threads=1
```

The focused MongoDB 7 Docker contract passed.

## ClickHouse named temporal timezones, 2026-09-27

A live ClickHouse 24.8 regression showed that `DateTime64(6, 'Asia/Tokyo')`
returned a Tokyo wall clock that TablePro decoded as a timezone-free timestamp.
That changed the instant by nine hours. The type metadata contains the IANA zone,
so the decoder now applies timezone rules and returns the corresponding UTC
`TimestampTz`, retaining the fractional seconds.

The decoder refuses unknown zones and local wall-clock strings that fall in DST
gaps or folds. The ClickHouse row format returns a local wall clock without its
offset, so an ambiguous returned value does not identify a unique instant and
must not be guessed. Untagged `DateTime` and `DateTime64` values remain
timezone-free `DateTime` values.

Unit tests cover type wrappers, Tokyo conversion, unknown zones, and New York DST
gaps/folds. A Docker integration test first failed with `DateTime(12:34...)`
instead of the expected `TimestampTz(03:34...Z)`, then passed after the fix. It
also checks that the instant survives a bound parameter and a SQL literal round
trip. The full ClickHouse integration suite passed all 23 cases. The combined `values`
layer passed in 113.058 seconds, `full` passed in 100.8 seconds, and the harness
passed. Reports are in `target/quality/20260927T180959352277Z-layers/`,
`target/quality/20260927T181245187611Z-layers/`, and
`target/quality/20260927T181435128973Z-layers/`.

The named-timezone contract now also checks `Asia/Kathmandu` at
`DateTime64(9)`, with a local time shortly after midnight mapping to the prior
UTC date. The expected instant is fixed independently as
`2026-09-26T18:30:00.123456789Z`; result decoding, typed binding and SQL-literal
round trips all retain nine digits. The focused Docker regression passed. The
strict GTK+DuckDB values layer also passed 169 selected tests across all 11
suites after this expansion:
`20261001T014227751433Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T014227751433Z-values/report.json`).

```sh
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration value_contract_datetime64_named_timezone_preserves_the_instant -- --ignored --exact --test-threads=1
```

A second Docker regression covers the New York fall-back `DateTime64(3)` local
time `2024-11-03 01:30:00.000`. The server confirms the exact local text and
reports an epoch in one of the two valid fold instants. Because the result wire
text omits which offset was used, BookiE returns `Undecodable`; SQL literal and
parameter consumers refuse it. The focused test passed against ClickHouse
24.8.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration value_contract_ambiguous_datetime64_local_time_is_refused -- --include-ignored --exact --test-threads=1
```

A third server check supplies the nonexistent spring-forward local time
`2024-03-10 02:30:00` to `DateTime64(3, 'America/New_York')`. ClickHouse 24.8
normalizes it to returned local time `01:30:00.000`; the server epoch oracle is
`1710052200000` (`2024-03-10T06:30:00Z`). BookiE decodes that normalized,
unambiguous server result to the exact UTC instant. This tests server behavior
for the supplied expression; it does not preserve the nonexistent civil input.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration value_contract_nonexistent_datetime64_input_matches_server_normalization -- --include-ignored --exact --test-threads=1
```

The fall-back contract now also covers Lord Howe Island's 30-minute transition
with `2024-04-07 01:45:00` in `Australia/Lord_Howe`. The unit case requires an
ambiguous-time refusal. ClickHouse's local text and either valid fold epoch are
checked independently; result decoding, SQL literal and parameter consumers
refuse the ambiguous value. The focused unit and Docker contracts passed, then
the strict GTK+DuckDB values layer passed all 190 tests across 11 suites and the
local quick gate passed. The run reused all 747 Cargo artifacts. See the
[review manifest](../evidence/b3-review-2026-10-01/manifest.json) for reports and
hosted CI status.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --lib temporal::tests::named_datetime_zones_decode_instants_and_refuse_dst_ambiguity -- --exact --test-threads=1
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration value_contract_ambiguous_datetime64_local_time_is_refused -- --include-ignored --exact --test-threads=1
```

Run the focused checks locally with:

```sh
cargo test --locked -p tablepro-driver-clickhouse --lib
cargo test --locked -p tablepro-driver-clickhouse --test integration -- --include-ignored --test-threads=1
./scripts/run-test-layer.py values
./scripts/run-test-layer.py full
```

Scoped Rust mutation evidence for `temporal.rs` is in
`target/quality/20260927-ch-temporal-mutants-final/mutants.out/outcomes.json`:
13 caught, 2 unviable, no survivors or timeouts. The initial mutation pass made
two synthetic wrapper results loop; the progress guard now exits safely and the
repeat has no timeout. Reproduce with:

```sh
mkdir -p target/mutation-tmp
TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-driver-clickhouse --file crates/drivers/clickhouse/src/temporal.rs --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260927-ch-temporal-mutants-final -- --lib
```

## ClickHouse `DateTime64(9)` server boundary behavior, 2026-09-29

The Docker contract checks the legal lower endpoint (`1900-01-01`) and upper
endpoint (`2262-04-11 23:47:16.854775807`) against independent
`toUnixTimestamp64Nano` results, including `i64::MAX` at the upper endpoint.
It also records asymmetric server behavior just outside the range. ClickHouse
24.8 accepts `1899-12-31 23:59:59.999999999` but clamps its year to 1900,
returning `1900-01-01 23:59:59.999999999`; the server epoch confirms the
transformed value. The first tested value above the upper endpoint instead
returns a query error.

BookiE refuses both out-of-range values as parameters and SQL literals before
submission. A caller's raw SQL can still invoke ClickHouse's own lower-bound
clamp; the driver cannot recover the original input from the server's valid
result. The test preserves that server behavior explicitly so it cannot be
mistaken for a lossless round trip.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration datetime64_nanosecond_boundaries_pin_server_clamp_and_local_refusal -- --include-ignored --exact --test-threads=1
```

The focused ClickHouse 24.8 Docker contract passed.

### Exact lower-precision DateTime64 bindings, 2026-09-30

A ClickHouse 24.8 native query proved that `DateTime64(0)` accepts
`2299-12-31 23:59:59` and returns the exact millisecond epoch. The driver's
parameter/literal code previously forced scale 9, then refused this value at
the Int64 nanosecond ceiling. The shared renderer now chooses the coarsest
scale that preserves every supplied fractional digit and fits the server
calendar and Int64 ticks. Year 2299 now round-trips through bound parameters and
SQL literals at every exact scale from 0 through 7, with native value and epoch
assertions. Core unit boundaries cover the scale-8 ten-nanosecond edge, the
scale-9 maximum and the first unrepresentable nanosecond. Forcing a value beyond
the scale-9 ceiling through an explicit scale-9 cast still produces a visible
server error; timestamps below the 1900 calendar bound still refuse locally.
The native regression, both focused boundary tests, core/driver unit tests, all
33 ClickHouse Docker integration tests, all 16 final-source scale-range mutants
and all 3 precision-selection mutants passed. Reports:
`target/quality/20260930-clickhouse-scale-precision-mutants/mutants.out/outcomes.json`,
`target/quality/20260930-clickhouse-scale-selection-mutants-final/mutants.out/outcomes.json`,
and `target/quality/20260930-clickhouse-scale-range-mutants-final4/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-core --lib clickhouse_datetime64_literal_uses_the_coarsest_exact_native_precision
rtk cargo test --locked -p tablepro-driver-clickhouse --lib datetime64_parameters_use_a_wider_exact_scale_when_subseconds_are_zero
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration temporal::second_precision_datetime64_beyond_nanosecond_limit_round_trips -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration datetime64_nanosecond_boundaries_pin_server_clamp_and_local_refusal -- --ignored --exact --test-threads=1
```

The in-range precision contract was also narrower than its test name: it
previously wrote only scales 0, 3, 6 and 9. It now inserts the same nine-digit
timestamp into `DateTime64(0)` through `DateTime64(9)`, checks each decoded
timestamp against an independently written truncation matrix, and compares each
result's native nanosecond epoch. The focused Docker test passed.
The strict GTK + DuckDB runner passed 156 selected tests across 11 suites with
no missing suites; report: `target/quality/20260930T184141165918Z-values/report.json`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration value_contract_datetime64_precision_0_through_9_is_exact -- --include-ignored --exact --test-threads=1
```

## DuckDB unsigned boundaries and mixed interval signs, 2026-09-30

The native DuckDB result contract now covers UBIGINT values immediately above
`i64::MAX` and at `u64::MAX`, checking the native type and exact server text as
well as SQL literal and bound-text round trips. The interval contract covers all
eight sign combinations across months, days and microseconds; each case checks
the decoded text, native type, `VARCHAR`, independent `date_part` values, SQL
literal re-import and explicitly cast parameter re-import. The existing decoder
unit contract separately refuses synthetic sub-microsecond interval payloads.

Both focused integration cases passed. Mutation testing ran the decoder's unit
and integration suites together: 11 mutants caught, one unviable, no missed or
timed out mutants. The report is
`target/quality/20260930-duckdb-native-values-mutants-with-unit/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-driver-duckdb --test integration value_contract_scalar_hugeints_preserve_exact_text_across_consumers -- --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-duckdb --test integration value_contract_interval_all_component_signs_round_trip_as_exact_text -- --exact --test-threads=1
```

## CSV file import and exact size boundaries, 2026-09-30

The focused import contracts now exercise `read_csv_file` with a real temporary
file, non-default tab delimiter, header handling and preview truncation. A sparse
file one byte over the file cap must be refused from its metadata. Shared file
size validation accepts exactly 64 MiB and refuses one byte more; independent
assertions pin the documented byte, field, column, row and preview limits.
Additional tests accept exactly 512 columns and a 1 MiB field, detect three
column comma/semicolon files, preserve the two-record header rule, and verify
`CsvFormat` conversion. The additive delimiter score was replaced by sampled
width because all delimiter candidates share the same CSV record boundaries.
The focused CSV import tests passed (28 selected). Its scoped 35-mutant run
caught 33, had two compile-time unviable replacements, and no missed or timed
out mutants. Evidence:
`target/quality/20260930-csv-import-boundaries-mutants-final/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-core import::csv_import::tests
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/import/csv_import.rs --re 'read_csv_file|check_file_size|read_csv|record_strings|check_width|detect_delimiter|delimiter_score|detect_header|CsvFormat|MAX_FILE_BYTES|MAX_FIELD_BYTES' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260930-csv-import-boundaries-mutants-final -- --lib -- --test-threads=1
```

### CSV inference and insert-plan mutation follow-up, 2026-09-30

The hosted core-3 mutation shard found missing assertions around inference and
plan construction. Import inference now proves blank and configured NULL-marker
cells do not widen a numeric column to text. SQLite's bool/int/float/decimal/
bytes type-name mappings are pinned to INTEGER/REAL/NUMERIC/BLOB. Plan tests now
check reported row count, exclude both auto-increment and generated fields from
the plan's columns and bound rows, and keep the SQL and row shapes aligned. The
placeholder plan already uses non-NULL synthetic values, so an explicit
`default_value: None` override was redundant and has been removed.

The focused import suite passed 70 tests. Scoped mutation runs caught 9 of 10
inference mutants (one was compile-time unviable) and 9 of 13 plan mutants (four
were compile-time unviable); neither run had missed mutants or timeouts. Evidence:
`target/quality/20260930-csv-infer-mutants/mutants.out/outcomes.json` and
`target/quality/20260930-csv-plan-mutants-final/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-core --lib import::
rtk cargo mutants --dir . --package tablepro-core --file crates/core/src/import/infer.rs --re 'infer_kind|sqlite_type' --test-tool cargo --timeout 30 --build-timeout 120 --output target/quality/20260930-csv-infer-mutants -- --lib import::
rtk cargo mutants --dir . --package tablepro-core --file crates/core/src/import/plan.rs --re 'row_count|insert_columns|insert_statement' --test-tool cargo --timeout 30 --build-timeout 120 --output target/quality/20260930-csv-plan-mutants-final -- --lib import::
```

### CSV export quoting and decimal-comma contracts, 2026-09-30

Export tests now check each `IfNeeded` quoting trigger independently: selected
delimiter, embedded quote, a line break replaced by a space, and formula
neutralization. Decimal-comma output accepts signed plain decimals while
preserving exponent forms, missing integer/fraction digits and nonnumeric text.
The focused core CSV export suite passed (16 tests). The scoped mutation run
caught 14 of 15 mutants with no timeout or unviable cases. Its only survivor
deletes `header_row` from the RFC 4180 row-writer options; this is equivalent
because `csv_row_line` never reads that option. Evidence:
`target/quality/20260930-csv-export-contract-mutants/mutants.out/outcomes.json`.

The streaming/file writer now compares directly with `render_csv` for both
header modes, including comma-decimal, delimiter quoting and line-break
replacement. A separate RFC 4180 header case keeps formula-like column names
unchanged. These regressions caught surviving mutations that omitted CSV
headers or enabled formula sanitization in the plain header writer. The
combined writer/header mutation run caught 5 of 6 mutants with no timeouts or
unviable cases; its only survivor deletes `header_row` from RFC row options,
which is equivalent for row rendering. Evidence:
`target/quality/20260930-csv-stream-and-rfc-mutants/mutants.out/outcomes.json`.
The current strict value-contract run passed 146 tests across all 11 selected
suites with GTK and DuckDB enabled, no missing suites, 709 fresh artifacts and
17 rebuilt packages. The quick layer also passed. Reports:
`target/quality/20260930T132204286258Z-values/report.json` and
`target/quality/20260930T131958872775Z-layers/report.json`.

```sh
rtk cargo test --locked -p tablepro-core --lib export::csv::tests
rtk cargo test --locked -p tablepro-core --lib value_contract_streamed_csv_matches_renderer_with_and_without_header
rtk cargo test --locked -p tablepro-core --lib rfc4180_csv_header_keeps_formula_like_column_names_unchanged
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/export/csv.rs --re 'CsvWriter|rfc4180_options' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260930-csv-stream-and-rfc-mutants -- --lib -- --test-threads=1
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/export/csv.rs --re 'is_plain_decimal|escape_csv_field' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260930-csv-export-contract-mutants -- --lib -- --test-threads=1
```

### Single-row JSON export, 2026-09-30

The public `row_to_json` consumer now has its own direct contract. It compares a
wide integer above 2^53, a BSON Decimal128 Extended JSON marker, a boolean and
SQL NULL with the expected JSON object. This closes a mutation survivor where
`row_to_json` could return an empty/default JSON value while `render_json`
tests still passed. The focused test passed, and its scoped mutation run caught
both generated mutations with no misses, timeouts or unviable cases. The strict
shared-value layer then passed 145 tests across 11 suites with GTK and DuckDB
enabled and no missing suites; the quick layer also passed. The strict report is
`target/quality/20260930T130742944866Z-values/report.json`. Evidence:
`target/quality/20260930-single-row-json-mutants/mutants.out/outcomes.json`.

```sh
rtk cargo test --locked -p tablepro-core --lib value_contract_single_row_json_export_preserves_value_types
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/export/json.rs --re 'row_to_json' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20260930-single-row-json-mutants -- --lib -- --test-threads=1
```

## SQL Server DATE, TIME and DATETIME2 calendar edges, 2026-09-30

A Docker-backed contract compares DATE year 0001/year 9999, TIME(7) minimum/
maximum and DATETIME2(7) minimum/maximum calendar values against independent
SQL Server text. It checks exact `Value::Date`, `Value::Time` and
`Value::DateTime` results, including the final 100 ns fractions, then binds
those values as parameters and exports/re-imports them as SQL literals. Native
text, decoded values and re-imported values must all agree. This narrows the
temporal gap for these three types; it does not establish support for
conversions outside chrono's range or other SQL Server temporal families. No
production defect was found.

The focused Docker test and the complete SQL Server integration suite passed;
the latter ran 32 tests in 166.73 seconds. The earlier targeted decoder mutation
run generated
one unviable mutant and no viable missed mutants, so it provides no additional
test-sensitivity evidence.

```sh
rtk cargo test --locked -p tablepro-driver-mssql --test integration temporal_boundaries::value_contract_supported_temporal_calendar_edges_match_native_text_and_bind_exactly -- --include-ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-mssql --test integration -- --include-ignored --test-threads=1
```

### MySQL repeated-semicolon script delimiter consumer contract, 2026-09-30

An editor-level regression uses `DELIMITER ;;` around a procedure containing
multiple semicolon-terminated body statements, followed by a delimiter reset
and a parameterized SELECT. Planner and execution statement extraction must
return exactly the routine and trailing query; the body placeholder must not
be extracted, the trailing placeholder must be preserved, and formatting then
replanning must retain the same two statements. This extends the existing
`$$` and `//` contracts to a delimiter that contains the ordinary SQL
semicolon. No planner or formatter defect was found.

```sh
rtk cargo test --locked -p tablepro-app --lib mysql_repeated_semicolon_delimiter_keeps_body_statements_together -- --test-threads=1
```

## DuckDB temporal filter precision, 2026-09-30

The shared filter builder now rejects predicates whose fractional input exceeds
the target DuckDB temporal type's precision. Equality, both `BETWEEN` bounds,
and each `IN` member use the same guard. TIME/TIMESTAMP/TIMESTAMPTZ accept
microseconds; `TIMESTAMP_S` and `TIMESTAMP_MS` enforce seconds and milliseconds.
`TIME_NS` and `TIMESTAMP_NS` retain nanosecond inputs. Exact millisecond and
nanosecond values remain accepted. This prevents filter parameters from silently
matching a rounded or truncated instant.

The first regression run failed before the guard existed because a sub-
microsecond TIME value was accepted. After the fix, the focused core contract
passed, then the strict GTK+DuckDB runner passed all 11 suites (156 tests):
`20260930T185810190323Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T185810190323Z-values/report.json`).
Scoped mutation testing of `parse_filter_value` caught 11 mutants; one mutation
was unviable. The guard is in shared filter construction; driver-specific
comparison semantics beyond DuckDB remain covered by the existing driver suites.
The same strict runner was rerun on corrected, pushed SHA
`1a8d9f459c5707f512b72ad77b04ed6921e56039`; all 156 selected tests again passed
across all 11 suites:
`20260930T192623654872Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T192623654872Z-values/report.json`).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-core duckdb_temporal_filters_refuse_values_the_column_would_truncate -- --nocapture
```

Embedded DuckDB integration tests now exercise filter output through real
parameter binding and native column comparisons. They check server-reported
`TIMESTAMP_MS`, `TIMESTAMP_NS`, `TIME_NS`, and `TIMESTAMPTZ` metadata and values;
the exact millisecond predicate selects only its matching row, while
sub-millisecond `TIMESTAMP_MS` and `TIMESTAMPTZ` predicates refuse before
execution. Nanosecond TIME/TIMESTAMP filters select their exact values through
the driver's lossless text fallback. An offset-origin TIMESTAMPTZ filter keeps
the exact instant through text binding and an `epoch_us` native oracle.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_temporal_filter_parameters_keep_duckdb_column_precision_end_to_end -- --exact --nocapture
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_time_ns_filter_uses_exact_text_fallback -- --exact --nocapture
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_timestamptz_filter_preserves_offset_origin_instant -- --exact --nocapture
```

### DuckDB sub-microsecond parameter expression boundary, 2026-10-01

Nanosecond `Time` and `DateTime` parameters use exact VARCHAR fallback because
the pinned Rust binding reduces native nanosecond values to microseconds.
Explicit casts to `TIME_NS` and `TIMESTAMP_NS` compare equal to exact native
nanosecond literals. The pinned DuckDB runtime rejects `TIME_NS + INTERVAL`
even after the cast, so that expression remains an explicit server limitation rather than
being coerced to microsecond `TIME`. `TimestampTz` remains canonical RFC3339
text, including all nine digits and the UTC instant. Grid edits to lower-
precision `TIMESTAMPTZ` columns continue to refuse sub-microsecond values.

The focused integration contract passed. Scoped mutation testing of
`time_param` and `timestamp_param` caught 8 of 10 generated changes; two were
unviable, with no missed or timed-out mutants. The strict GTK+DuckDB selector
passed 164 tests across all 11 suites, including 22 DuckDB tests:
`20260930T223807112958Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T223807112958Z-values/report.json`).
The mutation report is
`outcomes.json` (raw report unavailable in this checkout: `../target/quality/20261001-duckdb-temporal-bind-mutants/mutants.out/outcomes.json`).
The quick layer passed after the integration test was split into a support
module to satisfy the file-size guard:
`20260930T224147348085Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T224147348085Z-layers/report.json`).

```sh
rtk cargo test -p tablepro-driver-duckdb --test integration submicro_parameter_expression::value_contract_submicro_text_parameters_keep_precision_after_explicit_casts -- --exact --test-threads=1
```

The focused DuckDB crate passed all 41 tests. The strict value runner selects
integration tests by the `value_contract` name prefix. Its first rerun reported
17 DuckDB tests and omitted the first new case; renaming it to follow the
selection contract made it the 18th DuckDB case. After adding TIME_NS and
TIMESTAMPTZ native filter cases, the strict run selected 20 DuckDB contracts
and passed all 159 tests across 11 suites, with no missing suites:
`20260930T195202641431Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T195202641431Z-values/report.json`).

## DuckDB nested UHUGEINT refusal boundaries, 2026-09-30

The DuckDB gap audit added nested wide unsigned cases for a
`STRUCT(amount UHUGEINT)` value and a list of that struct. Independent native
`typeof` and `VARCHAR` results pin the full value `18446744073709551616`; the
BookiE result must be `Undecodable`, and SQL-literal and bound-parameter
consumers must refuse it. This expands explicit safe refusal to these two shapes
without claiming general nested collection support.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration value_contract_nested_uhugeint_struct_shapes_refuse_lossy_consumers -- --exact --nocapture
```

The focused native DuckDB case passed.
After adding this contract, the full DuckDB crate passed 42 tests and the strict
GTK+DuckDB runner passed all 160 selected tests across 11 suites, including 21
DuckDB contracts:
`20260930T200423574515Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T200423574515Z-values/report.json`).

## DuckDB nested UBIGINT array refusal, 2026-10-02

The scalar decoder preserves `UBIGINT` values above `i64::MAX`, but the nested
unsigned matrix did not include a `UBIGINT[]`. This contract uses
`i64::MAX + 1`, `u64::MAX` and SQL NULL. DuckDB `typeof` and `VARCHAR` projections
pin the native type and exact array text; BookiE marks the result `Undecodable`,
and SQL-literal and bound-parameter consumers refuse it. This records the
current safe boundary without claiming nested-array support.

```sh
rtk cargo test -p tablepro-driver-duckdb --test integration bigint_array::value_contract_nested_ubigint_array_refuses_lossy_consumers -- --exact --test-threads=1
```

The clean strict GTK+DuckDB layer passed 186 selected tests across 11 suites,
including 24 DuckDB contracts, with no missing suites on `6c2e61f`. See the
layer report (local ignored report, not portable: `../target/quality/20261002T003009990931Z-layers/report.json`)
and suite details (local ignored report, not portable: `../target/quality/20261002T003010044333Z-values/report.json`).
Other nested unsigned shapes remain open.

## DuckDB nested UBIGINT struct refusal, 2026-10-02

This contract extends the nested unsigned boundary to a STRUCT with
`i64::MAX + 1`, `u64::MAX` and a NULL field. DuckDB `typeof` and `VARCHAR`
provide independent type and exact-value oracles. BookiE returns
`Undecodable`, and SQL-literal and bound-parameter consumers refuse the value.
The focused embedded-engine test and clean strict GTK+DuckDB value layer passed
on `19c5b6a`: 187 tests across all 11 suites, including 25 DuckDB contracts.
Other nested unsigned shapes remain open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration bigint_struct::value_contract_nested_ubigint_struct_refuses_lossy_consumers -- --exact --test-threads=1
```

The report is
`20261002T005849903174Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T005849903174Z-values/report.json`).

## DuckDB nested UBIGINT map refusal, 2026-10-02

The native map contract now also covers `MAP(VARCHAR, UBIGINT)` with
`i64::MAX + 1`, `u64::MAX` and SQL NULL. DuckDB's independent `typeof` and
`VARCHAR` projections pin the type and exact `{key=value}` representation;
BookiE returns `Undecodable`, and SQL-literal and bound-parameter consumers
refuse the value. The focused test, clean strict GTK+DuckDB layer (188 tests,
11 suites, 26 DuckDB contracts) and local quick CI gate passed on `efcbec7`.
Other nested unsigned shapes remain open.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration bigint_map::value_contract_nested_ubigint_map_refuses_lossy_consumers -- --exact --test-threads=1
```

The strict report is
`20261002T072337041331Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T072337041331Z-values/report.json`),
and the quick-gate report is
`20261002T072915341877Z-quick/report.json` (local ignored report, not portable: `../target/quality/20261002T072915341877Z-quick/report.json`).

## DuckDB nested UHUGEINT fixed-array refusal, 2026-10-02

The fixed-size array boundary now has a wide-value contract for
`UHUGEINT[2]`, containing `18446744073709551616` and SQL NULL. Native
`typeof`/`VARCHAR` projections pin the fixed-array type and exact text; BookiE
returns `Undecodable` and SQL-literal/bound-parameter consumers refuse it. The
focused test passed. The strict GTK+DuckDB layer passed 189 tests across all 11
suites, including 27 DuckDB contracts, and local quick CI passed on `98611db`.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration fixed_uhugeint_array::value_contract_nested_uhugeint_fixed_array_refuses_lossy_consumers -- --exact --test-threads=1
```

The strict report is
`20261002T074300432752Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T074300432752Z-values/report.json`),
and the quick-gate report is
`20261002T074833600560Z-quick/report.json` (local ignored report, not portable: `../target/quality/20261002T074833600560Z-quick/report.json`).

## DuckDB nested UHUGEINT UNION refusal, 2026-10-02

The nested unsigned boundary now covers `UNION(value := 18446744073709551616::UHUGEINT)`.
DuckDB's native `typeof` and `VARCHAR` projections pin the result as
`UNION("value" UHUGEINT)` with exact decimal text. BookiE returns `Undecodable`,
and SQL-literal and bound-parameter consumers refuse it. The focused regression,
strict GTK+DuckDB layer (190 tests, 11 suites, no missing suites) and local
quick gate passed. The strict run reused 746 artifacts and rebuilt only the
DuckDB package.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-duckdb --test integration uhugeint_union::value_contract_nested_uhugeint_union_refuses_lossy_consumers -- --exact --test-threads=1
```

The strict report is
`20261002T080301493778Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T080301493778Z-values/report.json`),
and the quick-gate report is
`20261002T111624439672Z-quick/report.json` (local ignored report, not portable: `../target/quality/20261002T111624439672Z-quick/report.json`).
Hosted Build, Security and Flatpak workflows passed on docs tip `6e45fbf`.

## MySQL spatial grid edit refusal, 2026-09-30

The grid's GTK path rendered spatial bytes read-only, but direct driver-aware
edit parsing still accepted text for those same columns. A failing-first parser
contract reproduced this for `geometry`; it now requires refusal for all eight
MySQL spatial types. The Docker-backed app contract creates GEOMETRY, POINT and
MULTIPOLYGON rows, verifies native geometry type/WKT/HEX values, tries each
spatial edit through the parser, and confirms the native values and both row
identities remain unchanged.

Scoped mutation testing of `parse_mysql_spatial_input` caught two mutants; one
was unviable, with no missed or timed-out mutants. The strict GTK+DuckDB runner
passed all 162 selected tests across 11 suites, including the new parser and
live-server app contracts:
`20260930T203202118084Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T203202118084Z-values/report.json`).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib value_contract_mysql_spatial_parser_refuses_lossy_text_edits -- --nocapture
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib value_contract_mysql_spatial_grid_refusal_preserves_native_bytes -- --include-ignored --test-threads=1
```

## MongoDB in-flight cancellation and disconnect classification, 2026-09-30

A local TCP fixture accepts MongoDB's connection and holds it open after the
read starts. Cancelling the operation must return
`OperationOutcomeUnknown(Cancelled)`, not `Disconnected`; this distinguishes an
interrupted request with an unknown server outcome from confirmed transport
loss. The focused contract passed, and the complete MongoDB library suite passed
36 tests. The strict value runner passed 162 selected contracts across 11
suites; the library cancellation test was verified separately from that
runner's integration-test selection:
`20260930T210700047035Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T210700047035Z-values/report.json`).

```sh
rtk cargo test --locked --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --lib value_contract_mongodb_cancelled_inflight_read_is_unknown_not_disconnected -- --nocapture
rtk cargo test --locked --manifest-path linux/Cargo.toml -p tablepro-driver-mongodb --lib
```

## MySQL unsigned edit across session SQL modes, 2026-09-30

The existing contract set `SESSION sql_mode` through the pooled connection API,
then assumed later calls used that same physical connection. A new assertion
exposed the mismatch: the pool reset/reused a session with the server's default
mode. The contract now pins each mode with `open_session()`. In permissive mode,
MySQL demonstrates that `TINYINT UNSIGNED` value 256 clamps to 255. In a pinned
`STRICT_TRANS_TABLES` session, the native insert rejects 256, the app parser
refuses the same out-of-range grid edit, and a valid keyed edit still preserves
255 plus `BIGINT UNSIGNED` max while leaving the neighboring row unchanged.
The focused Docker contract passed. The strict GTK+DuckDB value runner passed
162 selected tests across 11 suites:
`20260930T210700047035Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T210700047035Z-values/report.json`).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib value_contract_mysql_unsigned_integer_grid_edits_refuse_coercion_and_preserve_u64 -- --include-ignored --test-threads=1
```

## ClickHouse nested decimal and temporal value, 2026-09-30

The native nested-value matrix now includes an array of tuples containing
`Decimal(38, 9)` and nanosecond `DateTime64(9, 'UTC')`. The contract compares
BookiE's decoded JSON with ClickHouse `toJSONString` and checks `toTypeName`
before verifying that SQL export, typed parameters and keyed grid editing
refuse the type-less nested value without changing the stored MergeTree row.
The focused Docker contract passed. Scoped mutation testing of `json_to_value`
caught 9 of 10 generated mutations; one was compile-time unviable, with no
survivors or timeouts. The strict GTK+DuckDB value runner passed 162 tests
across 11 suites, including the expanded ClickHouse case:
`20260930T213122442487Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T213122442487Z-values/report.json`).
The quick layer also passed:
`20260930T213517124497Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T213517124497Z-layers/report.json`).

The same server-backed contract was extended with an
`Array(Tuple(String, Array(Nullable(Decimal(38, 9)))))` value. Its independent
native JSON result preserves a high-precision Decimal, a NULL array element,
and an empty nested array. SQL export, parameter binding and keyed edit still
refuse type-less JSON, with exact native row equality after the refusal. The
JSON and CSV exports are parsed back through their consumers and compared with
the same native JSON oracle, preserving the nested value for downstream use.
The focused Docker case and strict GTK+DuckDB selector passed 164 tests across
11 suites:
`20260930T224745418261Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T224745418261Z-values/report.json`).
The quick layer also passed:
`20260930T225139833836Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T225139833836Z-layers/report.json`).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration value_contract_nested_collections_keep_exact_json_and_refuse_lossy_consumers -- --include-ignored --test-threads=1
```

### ClickHouse nested Map of tuple arrays, 2026-10-01

The same native-backed consumer contract now includes
`Map(String, Array(Tuple(String, Nullable(Decimal(38, 9)))))` with an empty
array, a NULL decimal and a high-precision decimal. It checks `toTypeName` and
`toJSONString`, then compares the driver value and parsed JSON/CSV exports with
that independent server oracle. The SQL literal, typed parameter and MergeTree
grid consumers must refuse the type-less nested value without changing the
stored row. The focused Docker case passed. Other nested combinations remain
open; this increases the matrix from nine tested shapes to ten, rather than
closing the broader nested-type audit. The strict values runner passed all 165
selected tests across 11 suites, including the expanded ClickHouse contract:
`20260930T231755592573Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T231755592573Z-values/report.json`).

### ClickHouse tuple containing a nullable-decimal map, 2026-10-01

The native-backed consumer contract now also covers
`Tuple(String, Map(String, Nullable(Decimal(38, 9))))`, including one exact
high-precision decimal and a NULL map value. The same test verifies the driver
result and parsed JSON/CSV against `toTypeName` and `toJSONString`, refuses SQL
literal, binding and grid writes without native type metadata, and confirms the
stored MergeTree row is unchanged. It now also covers
`Array(Map(String, Nullable(Decimal(38, 9))))` with the same decimal and NULL
values through those consumers. The focused Docker contract passed after both
shapes were added. This adds the twelfth nested shape; other nested combinations and broader consumer
parity remain open.

### ClickHouse numeric-key nullable map, 2026-10-02

The same server-backed contract now covers
`Map(UInt8, Nullable(UInt128))`, with key `255` mapped to NULL and key `1` mapped
to `18446744073709551616`. It checks ClickHouse's native type and JSON oracles,
the driver and parsed JSON/CSV consumers, and refusal by SQL literal, parameter
binding and keyed grid edit while confirming the MergeTree row is unchanged.
The focused Docker test and strict GTK+DuckDB value layer passed; the layer ran
186 tests across all 11 suites, including this contract. The report is
`20261002T004142618874Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T004142618874Z-values/report.json`).
This was the thirteenth nested shape; other nested combinations remained open.

### ClickHouse numeric-key map of nullable UInt128 arrays, 2026-10-02

The shared Docker contract now includes
`Map(UInt8, Array(Nullable(UInt128)))`, with a wide unsigned value and NULL in
one array plus an empty array under another key. ClickHouse `toTypeName` and
`toJSONString` provide native type and value oracles. Parsed JSON/CSV output
preserves the exact nested value; SQL literal, parameter and MergeTree grid
edit paths refuse it, and the stored row remains unchanged. The focused Docker
test, strict GTK+DuckDB layer (190 tests, all 11 suites) and local quick gate
passed. The strict run reused 745 artifacts and rebuilt ClickHouse and DuckDB.

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-clickhouse --test integration nested_values::value_contract_nested_collections_keep_exact_json_and_refuse_lossy_consumers -- --include-ignored --exact --test-threads=1
```

The strict report is
`20261002T120704261619Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T120704261619Z-values/report.json`),
and the quick-gate report is
`20261002T121254146544Z-quick/report.json` (local ignored report, not portable: `../target/quality/20261002T121254146544Z-quick/report.json`).

The reversed nesting order, `Array(Map(UInt8, Nullable(UInt128)))`, is also
covered with the same >`u64::MAX` value and SQL NULL. The native oracle and the
shared refusal/preservation checks pass through the same contract. The focused
Docker test and strict values layer passed; the quick gate passed when run with
loopback socket permission for existing MongoDB tests. Reports:
`20261002T124905277939Z-values/report.json` (local ignored report, not portable: `../target/quality/20261002T124905277939Z-values/report.json`)
and
`20261002T125842206487Z-quick/report.json` (local ignored report, not portable: `../target/quality/20261002T125842206487Z-quick/report.json`).

```sh
rtk cargo test -p tablepro-driver-clickhouse --test integration nested_values::value_contract_nested_collections_keep_exact_json_and_refuse_lossy_consumers -- --include-ignored --exact --test-threads=1
```

```sh
rtk cargo test --locked -p tablepro-driver-clickhouse --test integration value_contract_nested_collections_keep_exact_json_and_refuse_lossy_consumers -- --ignored --test-threads=1
```

### ClickHouse tuple containing a numeric-key nullable UInt128 map, 2026-10-04

The native-backed nested consumer contract now also checks
`Array(Tuple(String, Map(UInt8, Nullable(UInt128))))` with a value above
`u64::MAX` and a NULL map value. The ClickHouse `toTypeName` and `toJSONString`
oracles match the driver result; JSON/CSV output and CSV parsing preserve the
same value. Type-less SQL literal and parameter consumers refuse it, and a
keyed MergeTree grid edit is rejected with the stored id, value, type and JSON
unchanged. The focused Docker contract, strict ClickHouse Clippy and formatting
passed. The shared XLSX writer's nested Extended JSON exact-text test also
passes, but ClickHouse-specific workbook parity and spreadsheet-app re-import
remain open, as do other nested/type combinations; see the
[evidence manifest](../evidence/clickhouse-nested-tuple-map-results-2026-10-04/manifest.json).

## MongoDB late-page heterogeneity blocks grid editing, 2026-09-30

The first 50 documents declare a field as string; the next fetched page contains
a Decimal128 value for that field. A Docker-backed app contract obtains the
initial metadata and later page from MongoDB, merges the page schema through
`columns_for_browse_page`, and verifies the conflicting value marks the column
`mixed`, invalidates the cached grid layout, and fails the actual inline-edit
gate. A native MongoDB client confirms the Decimal128 value and row identity are
unchanged. This proves safety for each fetched page; it does not claim a global
type census for documents outside the current page.

The test passed in `20260930T215342621227Z-values/report.json`: 26 app tests and
163 tests across all 11 configured suites, including GTK and DuckDB. The quick
layer passed at the same source revision; see
`20260930T215742792833Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20260930T215742792833Z-layers/report.json`).

Scoped mutation testing of `columns_for_browse_page` passed its clean app-test
baseline. Three behavior-changing mutants were caught; three generated mutants
were unviable, with no missed or timed-out mutants. The isolated-copy attempt
ran no mutants because its duplicate GTK build exhausted temporary disk quota;
the retained in-place run reused the workspace target:
`outcomes.json` (raw report unavailable in this checkout: `../target/quality/20261001-mongodb-page-schema-mutants-inplace/mutants.out/outcomes.json`).

```sh
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-app --lib value_contract_mongodb_late_mixed_page_refreshes_grid_and_refuses_edit -- --include-ignored --test-threads=1
```

## PostgreSQL built-in array CSV INSERT matrix, 2026-10-01

The typed CSV INSERT path now has a live PostgreSQL round trip for all 20
array families in its static cast allowlist: boolean, bytea, name, integer
widths, oid, text, float, character types, numeric, UUID, date/time variants,
timestamps and intervals. The CSV is rendered and parsed through the shared
consumers, then `build_insert_plan` binds the exact array text through its
catalog-derived casts. Every target array is checked against both its native
text and `array_send` wire bytes. The fixtures include NULL and empty elements,
binary bytes, Unicode/newlines, numeric scale and specials, float subnormals,
temporal infinities/offsets, extended dates and mixed-sign intervals.

The focused Docker test passed one test with 64 filtered. The strict GTK+DuckDB
value runner passed 175 tests across all 11 suites, with no missing suites;
the PostgreSQL suite ran 37 selected tests, including this case. The full
disconnect/driver layer also passed 223 tests on the clean base commit before
this test-only addition. Evidence:
`20261001T031547325812Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T031547325812Z-layers/report.json`),
`20261001T025640026732Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T025640026732Z-layers/report.json`).
After adding the Docker case to the ignored-test inventory, the quick gate
passed as well:
`20261001T032311403470Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T032311403470Z-layers/report.json`).

The production cast mapping did not change in this checkpoint; its earlier
scoped mutation run caught all 26 generated mutations. The new live-server
matrix closes the gap that mapping tests could not prove: each static cast
actually inserts the driver's exported text as the correct PostgreSQL array.

## DuckDB interval CSV import, 2026-10-01

A failing-first embedded DuckDB contract found two importer bugs. The shared
catalog classifier treated `INTERVAL` as an integer because its name contains
`int`; after preserving interval cells as text, formula-safe CSV still prefixed
negative interval text, and an empty interval cell was mistaken for empty text
instead of SQL NULL. The importer now restores the leading marker only for
canonical DuckDB interval text with valid singular/plural units. With the
default empty null marker, an empty interval field becomes NULL; with a custom
marker, an empty interval literal is rejected. The classifier also keeps the
unrelated `POINT` catalog type as text.

The live CSV export/parse/`build_insert_plan`/INSERT test covers all eight
month/day/microsecond sign combinations, the month/day/microsecond carrier
extrema, zero and NULL. It compares exact imported values, `typeof`, native
`VARCHAR`, and independent `date_part` results for months, days and
microseconds. The focused contract passed. The strict GTK+DuckDB runner passed
176 tests across all 11 suites, with no missing suites; quick passed as well.
Mutation testing initially found three untested invalid unit spellings. After
adding them, the final scoped run caught 29/30 mutants, with one unviable and
none missed or timed out. Evidence:
`20261001T040526500083Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T040526500083Z-layers/report.json`),
`20261001T041008834602Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T041008834602Z-layers/report.json`),
`outcomes.json` (raw report unavailable in this checkout: `../target/quality/20261001-duckdb-interval-csv-mutants-final/mutants.out/outcomes.json`).

```sh
rtk cargo test --locked -p tablepro-core --lib import::cell::tests -- --test-threads=1
rtk cargo test --locked -p tablepro-driver-duckdb --test integration value_contract_interval_csv_import_preserves_native_components -- --test-threads=1
```

## ClickHouse Int128/UInt128 XLSX preservation, 2026-10-01

The ClickHouse wide-integer contract already verifies signed `Int128` minimum
and maximum plus `UInt128` maximum through native results, SQL literals,
parameters, CSV and grid edits. The shared XLSX writer test now includes these
three values as `Value::Text` and inspects the workbook XML to require exact
shared-string cells, preventing spreadsheet numeric conversion from losing
digits. A separate JSON contract requires them to remain exact JSON strings,
since JSON numbers cannot safely represent the full 128-bit range. Both focused
core tests passed. Scoped mutation testing of `write_cell`
and this contract caught all 15 generated mutants, with no misses, timeouts or
unviable mutations. The report is
`outcomes.json` (raw report unavailable in this checkout: `../target/quality/20261001-clickhouse-int128-xlsx-mutants/mutants.out/outcomes.json`).
The strict GTK+DuckDB value layer passed 177 tests across all 11 suites, with no
missing suites, and the quick layer passed. Reports:
`20261001T055114378394Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T055114378394Z-values/report.json`),
`20261001T055614415328Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T055614415328Z-layers/report.json`).

```sh
rtk cargo test --locked -p tablepro-core --lib export::xlsx::tests::value_contract_workbook_preserves_wide_integers_and_exact_decimals_as_text -- --exact --test-threads=1
rtk cargo test --locked -p tablepro-core --lib export::json::tests::value_contract_clickhouse_wide_integers_remain_exact_json_strings -- --exact --test-threads=1
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-core --file crates/core/src/export/xlsx.rs --re 'write_cell|value_contract_workbook_preserves_wide_integers_and_exact_decimals_as_text' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-clickhouse-int128-xlsx-mutants -- --lib -- --test-threads=1
```

## PostgreSQL unlisted built-in array refusal matrix, 2026-10-01

The binary array decoder allowlist did not have server-backed refusal evidence
for several built-in element OIDs even where scalar decoding is exact. A live
Docker contract now checks `inet[]`, `cidr[]`, `macaddr[]`, `macaddr8[]`,
`pg_lsn[]`, `bit[]`, and `bit varying[]`. For each, it requires a typed
`Undecodable` marker, verifies PostgreSQL's `pg_typeof` and array text against
fixed expected values, compares `array_to_json` with its native expected JSON,
and confirms SQL literal and parameter consumers refuse the value. This makes
the unsupported boundary explicit without claiming exact array support. The
focused Docker test passed all seven cases:
`array_contract::value_contract_unlisted_builtin_arrays_refuse_with_native_oracles`.
The complete PostgreSQL integration target passed 67 tests with
`--include-ignored --test-threads=1`. The strict GTK+DuckDB value layer then
passed 178 selected tests across all 11 suites, with no missing suites; its
PostgreSQL suite ran 38 selected tests and the log confirms this case ran.
Harness and quick also passed. Reports:
`20261001T061341105077Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T061341105077Z-values/report.json`),
`20261001T060930854105Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T060930854105Z-layers/report.json`),
`20261001T060932648747Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T060932648747Z-layers/report.json`).

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_unlisted_builtin_arrays_refuse_with_native_oracles -- --ignored --exact --test-threads=1
rtk cargo test --locked -p tablepro-driver-postgres --test integration -- --include-ignored --test-threads=1
```


## PostgreSQL built-in array OID census, 2026-10-01

A live catalog census now visits built-in array types, checks PostgreSQL's
`pg_typeof`, array text, and `array_to_json` oracles, then compares directly
decodable arrays against the decoder allowlist and checks SQL-consumer behavior.
It records 22 exact driver-level blockers instead of silently skipping them:
composite catalog arrays fail SQLx metadata decoding (`typcategory`, code 90),
multirange arrays fail SQLx type decoding (`typtype`, code 109), and
`aclitem[]`/`gtsvector[]` fail with PostgreSQL SQLSTATE 42883 because no binary
output function exists. Each blocker has server-side native oracles. The known
set is asserted exactly so new driver errors fail the census. `name[]` is checked
separately because its catalog row does not appear in this array enumeration.
This establishes refusal/blocker evidence; it does not add support for these
arrays or resolve the SQLx/PostgreSQL binary-protocol limitations.
The focused test passed against the local Docker PostgreSQL fixture. The full
PostgreSQL integration target passed 68 tests; harness/quick passed, and strict
GTK+DuckDB value validation passed 179 tests across all 11 suites with no missing
suites. Reports: `20261001T064515312579Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T064515312579Z-values/report.json`),
`20261001T064121314717Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T064121314717Z-layers/report.json`).

```sh
rtk cargo test --locked -p tablepro-driver-postgres --test integration array_contract::value_contract_builtin_array_oid_census_matches_decode_allowlist -- --ignored --exact --test-threads=1
```


## MongoDB Int32 grid edits preserve BSON width, 2026-10-01

A failing-first live app contract found that BSON `int` cells decode to the shared
`Value::Int` and were rebound as BSON Int64. It also found the parser accepted
values beyond Int32 and could let MongoDB change the stored numeric value. For
MongoDB `int` columns, grid parsing now checks the signed Int32 bounds and emits
canonical Extended JSON `$numberInt`; `long` columns remain exact Int64. The live
contract edits both widths through the app parser and keyed-update builder, checks
row identity and native BSON kinds, and verifies overflowing Int32 input is refused
with the stored Int32 unchanged. The parser unit contract checks both Int32
boundaries, adjacent overflow, Int64 min/max and values above 2^53, and keeps other
drivers on their existing path. The first live regression failed because Int32
overflow was accepted; after the fix the focused live and parser tests passed.
The full strict GTK+DuckDB layer passed 181 tests across all 11 suites with no
missing suites. A scoped run caught all four viable parser mutants; one generated
whole-function replacement was unviable, with no misses or timeouts. Reports:
`20261001T071947669210Z-values/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T071947669210Z-values/report.json`), `20261001T072421865121Z-layers/report.json` (raw report unavailable in this checkout: `../target/quality/20261001T072421865121Z-layers/report.json`), and `mutation outcomes` (raw report unavailable in this checkout: `../target/quality/20261001-mongodb-integer-width-mutants-final/mutants.out/outcomes.json`).

```sh
rtk cargo test --locked -p tablepro-app --lib ui::browse_tab::value_parse::mongodb_integer_width::value_contract_mongodb_integer_parser_preserves_int32_and_int64_widths -- --exact --test-threads=1
rtk cargo test --locked -p tablepro-app --lib ui::browse_tab::value_parse::mongodb_integer_width::value_contract_mongodb_int32_grid_edit_preserves_integer_width -- --include-ignored --exact --test-threads=1
rtk env TMPDIR=$PWD/target/mutation-tmp CARGO_TARGET_DIR=$PWD/target cargo mutants --package tablepro-app --file crates/app/src/ui/browse_tab/value_parse.rs --re 'parse_mongodb_integer_input' --test-tool cargo --timeout 30 --build-timeout 180 --output target/quality/20261001-mongodb-integer-width-mutants-final -- --lib ui::browse_tab::value_parse::mongodb_integer_width::value_contract_mongodb_integer_parser_preserves_int32_and_int64_widths
```

## PostgreSQL extended temporal consumer support (October 3)

PostgreSQL DATE values outside Chrono's calendar and upper finite TIMESTAMP /
TIMESTAMPTZ values now retain exact text through results, SQL literals, typed
casts, CSV import and app keyed edits. A native send-byte oracle checks the
result and persisted edit; the app contract also checks the full row key and an
unchanged sibling. Year 1,000,000 DATE and year 294276 upper timestamps have
consumer coverage. The maximum finite DATE `5874897-12-31` has result, literal
and binding byte checks. These cases use exact text fallback; they do not prove
generic PostgreSQL custom-type support.

## PostgreSQL BC and extended-year CSV import (October 3)

The default sanitized CSV import contract covers BC, AD, year 9999, year 10000
and SQL NULL for DATE, TIMESTAMP and TIMESTAMPTZ, then compares PostgreSQL's
native send bytes after import. The first full values run found that Chrono's
valid leading `+` for year 10000 was rejected; after fixing validation and
canonicalizing the year before PostgreSQL binding, the focused Docker test
`date_contract::value_contract_bc_dates_survive_default_csv_import` passed.
The strict GTK+DuckDB values layer passed 196 selected tests across all 11
suites, with no missing suites, on the merged working tree (`origin/linux` at
`6346a431c` integrated on top of `cdcfcb0`). This report records a dirty
worktree before the merge commit:
`20261003T002033438424Z-values/report.json` (local ignored report, not portable: `../target/quality/20261003T002033438424Z-values/report.json`).

## DuckDB extended calendar and TIMESTAMPTZ consumer support (October 3)

DATE32 edges and DATE/TIMESTAMP values outside Chrono's calendar retain exact
text. Results, SQL literals, parameters, CSV import and keyed edits are checked
against DuckDB's native text/epoch oracles. Extended TIMESTAMPTZ also preserves
its UTC offset and offset-origin instant through those consumers. Installed GTK,
arbitrary nested collection combinations and native sub-microsecond bindings
remain outside this evidence.

## MongoDB collection-wide heterogeneity blocks grid editing (October 3)

`fetch_columns` scans the collection and marks a field `mixed` when a late
Decimal128 conflicts with earlier strings. The app Docker contract verifies
first-page String and later-page Decimal128 cells remain read-only, checks the
`$numberDecimal` marker and confirms the persisted BSON kind and row identity.
The driver contract checks the late-page value through browse and query. This
proves the named fixture; full-scan cost and concurrent writes during the scan
remain risks. The October 3 follow-up below closes the separate census/page
command gap for browse rows, but does not add snapshot semantics.

### MongoDB missing fields remain distinct from BSON null (October 3)

A native sparse-document contract first failed because the driver returned
`Value::Null` both for an explicit BSON null and for a field absent from a
document. The driver now returns `Value::Undecodable("missing BSON field")`
for the absent field, which stays visibly distinct and cannot be rebound as an
explicit null. The test independently reads both source documents through the
MongoDB client, then checks the driver query result by `_id`. The focused Docker
regression and the full driver package test run passed (65 tests across three
suites). This closes the representation conflation without claiming a general
missing-value type in the shared model. Collection census cost and concurrent
writes during the scan remain open. Commands, initial failure, and fingerprints
are in the [case manifest](../evidence/mongodb-missing-null-results-2026-10-03/manifest.json).

## MCP CSV null markers preserve PostgreSQL enum values (October 3)

CSV file and MCP `export_data` outputs include a null marker chosen to be absent
from exported values. The marker starts at `\\N` and appends `N` until it no
longer collides, so enum labels `\\N` and `\\NN` remain text. The app shows
the marker in its CSV export dialog, and its import dialog accepts the same
value. Native PostgreSQL contracts import the exact MCP response and core file
output into schema-aware enum targets, checking literal `NULL`, empty text,
Unicode, SQL NULL, marker-shaped labels, formula-shaped text in raw mode, and
`pg_typeof`. Formula-shaped text is prefixed when spreadsheet-safe export is on;
turning it off preserves the literal value for import. The ordinary blank
format remains safe: enum import refuses it as ambiguous before any write.
This does not add an MCP import tool. The grid context-menu CSV serializer now
chooses a collision-free NULL marker so SQL NULL, an empty enum label, literal
`NULL`, and marker-shaped labels remain distinct in clipboard output. Formula
sanitization remains enabled, so clipboard output is not a lossless restore
format; see the [clipboard serializer evidence](../evidence/postgres-enum-clipboard-csv-results-2026-10-04/manifest.json).
Other enum format/session coverage remains open.
Commands and fingerprints are in the
[PostgreSQL enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### Grid clipboard CSV preserves enum NULL and empty text (October 4)

The grid context-menu CSV serializer now uses a NULL marker selected to be
absent from the copied rows and keeps formula sanitization enabled. Its pure
app regression covers literal `NULL`, an empty enum label, SQL NULL, collisions
with `\\N` and `\\NN`, and formula-shaped text, with and without headers. The
focused test and all 441 non-ignored app library tests pass; 20 tests remain
ignored. Strict app Clippy and formatting pass. This verifies serialization
only; OS clipboard delivery, spreadsheet paste/import, and lossless treatment
of formula-shaped labels remain unverified. See the
[clipboard CSV evidence](../evidence/postgres-enum-clipboard-csv-results-2026-10-04/manifest.json).

## Spreadsheet-safe PostgreSQL enum CSV is not reversible (October 3)

A PostgreSQL 16 regression adds both formula-shaped enum label =1+1 and the
distinct literal label '=1+1. Spreadsheet-safe export prefixes the first label
with an apostrophe, producing the same CSV field for both source values. The
schema-aware importer treats both fields as exact enum text, and PostgreSQL
stores the apostrophe-prefixed label for both rows. This is a valid native enum
value but a lossy restore. Raw-text export preserves both labels and remains the
tested lossless import path. The export dialog now says to turn spreadsheet
safety off for lossless re-import. See the native selector and retained output
in the [PostgreSQL enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

## PostgreSQL domain over enum value consumers — 2026-10-03

A PostgreSQL 16 native regression creates a domain over a custom enum and
projects its literal `NULL` label, Unicode label and SQL NULL. The driver returns
exact text/NULL values while the independent `pg_typeof` column reports the
domain type. A companion array contract covers literal `NULL`, empty text,
Unicode, a comma-containing label and an SQL NULL element; `array_to_json` and
`pg_typeof` provide independent native value/type oracles. It initially failed
because the binary decoder treated the domain element OID as unsupported. The
array decoder now follows domain metadata to its enum base and returns exact
PostgreSQL array text. The focused contract and full PostgreSQL integration
suite passed. A separate native contract binds text and SQL NULL through an
explicit domain cast, then updates a domain column and verifies the stored
label and `pg_typeof`. This tests explicit-cast parameter and update consumers;
implicit equality between two domain values is unsupported by PostgreSQL and
is not claimed. A failing-first assignment-context test reproduced SQLSTATE
42804 because the driver bound a server-inferred domain parameter as text. The
parameter describer now follows domain metadata to the enum base; an uncast
text update and SQL NULL update both preserve the domain type and leave a
same-table sibling unchanged. Structured equality/IN/IS NULL filters cast the
domain column and values through the base enum; native results verify exact
labels, SQL NULL, and the domain type. The catalog metadata also feeds keyed
updates and draft inserts, with the server verifying the stored domain type. A
raw CSV round-trip exports a domain-over-enum column with an explicit `\\N` NULL
marker and imports literal `NULL`, empty text, Unicode and SQL NULL into the
domain. The default blank representation is refused before any target rows are
written; the imported values and native domain type are checked against native
expected rows. Shared JSON rendering and the JSON result-file writer preserve
the domain labels and SQL NULL as JSON strings/null, with `pg_typeof` confirming
the source type. A SQL result-file contract replays quoted/adversarial values
into a same-domain destination; exact native values/types survive and the
statement-shaped label does not alter a neighboring table. Domain
MCP coverage exercises `execute_query`, JSON and CSV `export_data`, then imports
the exact emitted CSV with its marker and checks native domain values/types.
XML/HTML/Markdown file outputs preserve NULL/empty distinctions, Unicode and
escaped hostile labels. XLSX writes the non-empty domain labels as a workbook
and refuses the empty label while preserving the existing destination.
Additional PostgreSQL domain/session format combinations, other operator
contexts and nested domain chains remain untested. A new query comparison case
proves raw `domain = $1` is rejected by PostgreSQL with SQLSTATE 42883, while
casting the column to its base enum lets PostgreSQL infer the enum type for
bound text and SQL NULL parameters; `pg_typeof` and row outcomes are checked.
Exact commands and results are in the
[enum evidence manifest](../evidence/postgres-enum-results-2026-10-03/manifest.json).

### Domain-over-enum filter operator follow-up (October 3)

The native filter contract was expanded from equality, `IN` and `IS NULL` to
also cover `<>`, `<` and `BETWEEN`. Rows assert exact enum labels, keep literal
`NULL` distinct from SQL NULL, and report the original domain through
`pg_typeof`. The focused PostgreSQL 16 Docker contract and all 10 domain
contract tests pass; other domain operators and session configurations remain open. See the
[operator evidence](../evidence/postgres-domain-enum-filter-results-2026-10-03/manifest.json).

### Domain-over-enum query parameter operator follow-up (October 3)

The direct query comparison contract now checks the base-enum-cast `<>` and
`BETWEEN` operators in addition to `=`. PostgreSQL infers the enum parameter
type for both BETWEEN bounds; native `pg_typeof` and row truth-value assertions
pass. Raw domain `= $1` continues to fail with SQLSTATE 42883, as recorded by
the same contract. The full domain suite passes all 10 tests. Other direct
operator and session configurations remain open. See the
[query-operator evidence](../evidence/postgres-domain-enum-query-operators-results-2026-10-03/manifest.json).

## MongoDB browse metadata and cursor consistency — 2026-10-03

`fetch_rows` now builds collection-wide type metadata and retains requested
page rows from one cursor. A MongoDB 7 failpoint pauses `getMore` before an
off-page document is read, then a native update changes its field from String
to Decimal128. The returned page reports `mixed`, preserves its already-read
String rows as canonical Extended JSON, and the app refuses their edits. Native
reads verify the changed Decimal128 and unchanged sibling. A second failpoint
test skips the first `find` and blocks a second; the browse request completes
without that second command. The earlier inter-command regression failed with
stale `string` metadata and is retained as the before-fix result. The final
app-server layer passed all 12 registered tests.

The consistency contract is best-effort, not snapshot isolation. A deterministic
failpoint test updates `_id: 0` from String to Decimal128 after the cursor has
read it but before `getMore`; the returned row and census still say String while
a native read sees Decimal128. A concurrent change to a document the cursor
has already passed is therefore outside the metadata guarantee. MongoDB grid
updates now compare the displayed original value for each edited field in the
same atomic update filter, so a same-field concurrent change reports a conflict
instead of being overwritten. This value guard does not detect an ABA change
that returns the field to its original value. Stale keyed deletes now guard all
non-key values present in the materialized row; they still do not detect ABA or
changes to fields introduced after the result's column set was materialized.

## MongoDB stale grid edits use atomic original-value guards — 2026-10-04

A failing-first MongoDB 7 contract reads two documents, then changes one field
through a native client before saving the stale grid values through BookiE. The
first run matched the `_id` alone, returned one affected row and overwrote the
newer value. The fixed app materializer includes each edited field's original
value in the same `update_one` filter; both stale writes now match zero rows.
The contract verifies a concurrent string edit remains stored, that a
concurrent removal of an explicitly NULL field stays missing, and that changing
explicit NULL to an array containing NULL is preserved. MongoDB matches NULL
guards with equality, field existence, and a non-array check, preserving the
distinction between explicit BSON NULL, missing fields, and arrays that contain
NULL. This is per-edited-field compare-and-set, not document-version tracking:
ABA changes remain open. See the [evidence manifest](../evidence/mongodb-stale-grid-edit-results-2026-10-04/manifest.json).

## MongoDB keyed deletes compare the materialized row — 2026-10-04

A failing-first MongoDB 7 contract showed that the app generated a parameterized
keyed DELETE while the MongoDB driver rejected bound DELETE statements. The
driver now accepts a single-collection DELETE with a bound equality/AND filter
and executes `delete_one`. The app materializer adds every materialized
non-primary-key value to that filter; BSON NULL guards require an existing
non-array NULL field, and the missing-field marker becomes `$exists: false`.
The native contract proves an unchanged row is deleted, while concurrent
changes to the payload, an untouched sibling field, explicit NULL becoming
missing, and explicit NULL becoming an array containing NULL all return zero
deleted rows and preserve the new values.
This guards the visible row snapshot rather than providing document-version or
snapshot isolation: ABA changes and fields added outside the materialized
column set remain open. See the [evidence manifest](../evidence/mongodb-stale-grid-delete-results-2026-10-04/manifest.json).

The shell `run_find` path still runs a full type census and then a filtered
query. It merges types from returned rows, so a selected row that changes kind
between those commands becomes `mixed`; off-page changes after census are not
visible to that merge. CSV and JSON export use the materialized query result and
preserve canonical Extended JSON markers for observed mixed values. Export does
not refresh data or establish a collection snapshot. A diagnostic Docker test
measures full-census time for 1,000 and 10,000 documents with a 50-row page;
results are machine-specific and have no pass/fail threshold. These boundaries
are covered by [the MongoDB census evidence manifest](../evidence/mongodb-census-results-2026-10-03/manifest.json).

## SQLite REAL float edge checkpoint (2026-10-03)

SQLite's `REAL` binding must preserve floating-point bits it can store and refuse
inputs whose meaning SQLite changes. An independent `typeof(value)` query
confirms `f64::from_bits(1)`, `f64::MAX`, positive infinity and negative
infinity are stored as `real`; the returned floats retain their exact `to_bits()`.
NaN previously succeeded as an insert and became SQLite NULL, while negative
zero came back with the positive-zero bit pattern. Both parameter writes now
return `DriverError::Unsupported` before dispatch. The generated INSERT literal
path also refuses negative zero as `UnrepresentableValue`; a postcondition
asserts both refused writes leave the table empty.

Selectors: `sqlite_real_storage_preserves_float_edge_bits` and
`sqlite_real_binding_refuses_negative_zero_and_nan` in
`crates/drivers/sqlite/tests/integration.rs`. The native integration suite passed
23 tests; local `quick` and `change-contracts` layers also passed. Their retained
report and source fingerprints are in
[`sqlite REAL evidence`](../evidence/sqlite-real-results-2026-10-03/manifest.json).

## PostgreSQL nested domain-over-enum chain (2026-10-03)

A PostgreSQL 16 fixture nests two domains over a custom enum and checks exact
projection values plus the outer `pg_typeof`. Before the fix, `fetch_columns`
returned no enum metadata for the domain column because the catalog lookup
unwrapped only one domain layer. That omission prevented the existing
schema-aware filter/keyed-update/draft-insert builders from using the base enum
cast. The catalog now follows `pg_type.typbasetype` recursively until it finds
the enum leaf. The regression verifies the resolved qualified enum metadata,
literal label `NULL` filtering, keyed update, draft insert, inferred text and
SQL NULL transaction writes, invalid-label SQLSTATE `22P02`, and unchanged
native values/types for all rows.

The focused new selector and all 92 PostgreSQL integration tests passed. Clippy
passed for all PostgreSQL targets. The initial native assertion failure and
current logs/source fingerprints are in the
[nested-domain evidence manifest](../evidence/postgres-nested-domain-results-2026-10-03/manifest.json).
PostgreSQL 16 rejects an uncast raw comparison between this domain column and
an unknown text parameter with SQLSTATE `42883`; the test keeps that boundary
explicit and verifies that casting both sides to the base enum returns the
literal `NULL` label. Structured filters already produce those base-enum casts.
Automatic inference for raw domain comparisons and other enum
session/configuration combinations remain open.

## PostgreSQL three-level domain-over-enum chain (2026-10-03)

The nested-domain native fixture now inserts a third domain layer between the
enum and the table column. The same PostgreSQL 16 contract still resolves the
qualified enum leaf, preserves the outer domain type in projections and checks
filters, keyed/draft writes, inferred parameters, invalid-label refusal and
unchanged rows. The focused selector and all 92 PostgreSQL integration tests
passed, as did Clippy and `change-contracts`. This extends proof to three
domain levels; it does not prove arbitrary depth or other enum/session
configurations. See the
[three-level evidence packet](../evidence/postgres-three-level-domain-results-2026-10-03/manifest.json).

## PostgreSQL three-level domain query distinctness parameters (2026-10-03)

The three-level fixture now exercises direct `IS DISTINCT FROM` and
`IS NOT DISTINCT FROM` parameters for text and SQL NULL without an explicit
parameter cast. `pg_typeof($1)` confirms inference as the qualified leaf enum,
while `pg_typeof(status)` remains the outer domain. Exact truth tables include
the literal label `NULL`, empty label, Unicode label and SQL NULL. The focused
contract and all 10 domain contracts pass, along with Clippy and formatting.
See the [query-operator evidence](../evidence/postgres-three-level-enum-query-operator-results-2026-10-03/manifest.json).

At the October 3 checkpoint, depths beyond three levels and other enum/session
configurations remained open.

## PostgreSQL four-domain-layer enum consumer contract (2026-10-04)

A new PostgreSQL 16 integration case builds four nested domains over one enum.
It verifies that fetched column metadata resolves to the schema-qualified enum
leaf, keyed and assignment-inferred updates store labels at the four-layer
outer domain, and both a server-inferred enum comparison and typed equality
filter select the intended rows. A query that also asks for
`pg_typeof($1)` is refused with native SQLSTATE `42P08`; adding an explicit
qualified enum cast is the passing control. Independent `pg_typeof` and value
queries confirm the outer domain type and that a sibling SQL NULL remains
unchanged. All 11 PostgreSQL domain contracts passed, including the existing
three-layer parameter cases. Domain chains deeper than four layers and other
enum/session combinations remain open. See the
[four-domain-layer evidence](../evidence/postgres-four-level-domain-results-2026-10-04/manifest.json).

## PostgreSQL five-domain-layer enum contract (2026-10-04)

A PostgreSQL 16 native case extends the chain to five nested domains. Fetched
metadata resolves to the schema-qualified enum leaf; a schema-aware keyed edit,
server-inferred enum comparison/update parameters, and a typed equality filter
preserve the five-layer outer domain. An invalid label is refused with SQLSTATE
`22P02`, and independent stored-value/type checks confirm no partial change and
preserve the neighboring SQL NULL. All 12 domain contracts passed, including
the four-level case. Chains deeper than five and other enum/session combinations
remain untested. See the [five-domain-layer evidence](../evidence/postgres-five-level-domain-results-2026-10-04/manifest.json).

## PostgreSQL six-domain-layer enum contract (2026-10-04)

A PostgreSQL 16 native case extends the enum chain to six nested domains.
Catalog metadata resolves to the qualified enum leaf while the session
`search_path` resolves a same-named shadow enum with a narrower label set.
Schema-aware keyed and draft writes preserve the six-layer outer domain for an
enum label and SQL NULL; a typed equality filter selects the expected rows.
An invalid label is refused with SQLSTATE `22P02`; native value/type checks
confirm the row is unchanged and its SQL NULL sibling remains intact. The
focused case and all 13 PostgreSQL domain contracts passed, along with Clippy,
formatting and ignored-test inventory checks. Chains deeper than six layers and
other enum/session combinations remain untested. See the
[six-domain-layer evidence](../evidence/postgres-six-level-domain-results-2026-10-04/manifest.json).

## PostgreSQL seven-domain-layer enum contract (2026-10-04)

The shadowed-search-path contract now runs at both six and seven nested domain
levels. Each depth checks enum-leaf metadata, a same-named narrower shadow
enum, keyed update, draft inserts with label and SQL NULL, typed filtering,
invalid-label refusal (`22P02`), stored outer-domain type/value and an unchanged
NULL sibling. The combined native PostgreSQL 16 test passed, as did PostgreSQL
driver Clippy and formatting. Chains deeper than seven and other enum/session
combinations remain untested. See the
[six/seven-level evidence](../evidence/postgres-seven-domain-results-2026-10-04/manifest.json).

## SQLite STRICT ANY runtime-kind-preserving grid edits (2026-10-03)

A SQLite STRICT table can declare `ANY` while storing different runtime kinds
in one column. Before the fix, the app parsed every `ANY` grid edit as text: a
REAL value edited from `1.5` to `2.75` became SQLite TEXT, and an INTEGER edit
also became TEXT. The grid now uses the existing cell's `Value` kind when
parsing an edit to an SQLite `ANY` column: INTEGER remains integer, REAL remains
real, and TEXT remains text. A native `typeof(value)` query checks the persisted
kind and value for each row. For a NULL or new cell, empty input follows the
shared nullable-column rule and stores NULL; nonempty input stays TEXT, even
when numeric-looking, because there is no existing runtime kind to preserve and
the grid must not guess a conversion.

A follow-up found that clearing existing nonempty TEXT through the grid was
parsed as SQL NULL. The grid-cell parser now preserves an existing SQLite
STRICT `ANY` TEXT cell as empty TEXT when its input is blank; blank NULL and
draft cells still store SQL NULL. The native regression failed before the
change with `typeof(value) = 'null'`, then passed with `typeof(value) = 'text'`
and an empty returned string after the fix.
The focused app regression passed, as did the DuckDB-enabled app-library suite
(444 passed, 20 ignored), Clippy, and the mapped `change-contracts` layer.

The SQLite-backed app regression directly exercises the grid-cell parser,
keyed-update builder and driver write; it does not drive GTK event handling.
`sqlite_strict_any_null_and_new_cells_use_text_unless_blank` checks that input
policy through a keyed edit and draft insert, with native storage-class/value
assertions.
`sqlite_strict_any_blob_values_are_read_only_and_keep_exact_bytes` adds the
other supported SQLite storage class: the driver returns exact BLOB bytes and
the shared runtime-value gate refuses inline editing. The independent native
oracle checks `typeof(value) = 'blob'` and the original bytes. The regression
checks the gate directly; installed GTK behavior remains unverified.
The app-library suite passed 436 tests with 20 ignored, including
`sqlite_strict_any_grid_edit_preserves_each_rows_runtime_storage_class`.
The follow-up app-library suite passed 438 tests with 20 ignored, including the
NULL/new-cell policy and BLOB refusal contracts. Clippy and the mapped `change-contracts` layer
passed. The failing-first log, full app test logs, local layer reports, and
source fingerprints are in the
[STRICT ANY evidence packet](../evidence/sqlite-strict-any-results-2026-10-03/manifest.json).

## SQLite compound SELECT provenance over STRICT ANY (2026-10-04)

A new native regression found that SQLite origin metadata on a `UNION ALL`
result can point at the first branch's STRICT `ANY` column even when later
branches return text and SQL NULL. The driver now keeps SQLx's fallback
metadata for compound results, including a CTE or derived-table wrapper, and
for query syntax it cannot classify. `typeof()` independently confirms the
integer, text and NULL storage classes; ordinary, bound and transaction paths
return the same cells. A direct table-column query still reports `ANY` when an
unrelated UNION exists only in its filter. The focused test, all 47 driver tests
and five app STRICT-ANY contracts passed, as did Clippy and formatting. Other
computed-expression shapes and consumers remain open. See the
[compound-result evidence](../evidence/sqlite-union-any-results-2026-10-04/manifest.json).

## SQLite compound STRICT ANY result CSV/XLSX output (2026-10-04)

An app-level result-file contract materializes a native compound SQLite query
containing INTEGER, TEXT and SQL NULL. CSV output retains its exact textual
rows. The real XLSX workbook stores the integer as a numeric cell, the text as
a shared string, and NULL as an absent cell. Six SQLite app `ANY` contracts
passed with strict Clippy and formatting. This proves workbook cell output, not
spreadsheet-application re-import. A later typed CSV case closes the native
SQLite result-to-CSV-to-import gap; see the
[compound-result CSV/XLSX evidence](../evidence/sqlite-union-any-export-results-2026-10-04/manifest.json)
and [typed CSV evidence](../evidence/sqlite-union-any-csv-roundtrip-results-2026-10-04/manifest.json).

## SQLite compound STRICT ANY typed CSV round trip (2026-10-04)

Reproduction showed that a compound query's fallback `NULL` metadata caused
INTEGER 42 to return from CSV import as TEXT. SQLite result-file exports now
tag non-NULL values in fallback-metadata columns; import decodes those tags
against each destination column's declared type. A native app contract exports
and re-imports compound output containing INTEGER, TEXT, BLOB, SQL NULL, and
text that resembles the reserved tag prefix. `typeof()` confirms the typed
`ANY` result retains each runtime storage class, while INTEGER and TEXT target
columns keep their declared behavior. Seven SQLite app `ANY` contracts, 514
core tests plus 10 query-pipeline tests, all 47 SQLite driver tests, strict
Clippy and formatting passed. Spreadsheet-app re-import and other computed
expression consumers remain open; CASE consumer coverage is recorded below. See the
[typed CSV evidence](../evidence/sqlite-union-any-csv-roundtrip-results-2026-10-04/manifest.json).

## SQLite computed CASE STRICT ANY CSV round trip (2026-10-04)

An app-level native contract exports a computed `CASE` result over STRICT
`ANY` through the result-file CSV writer, imports it into typed SQLite
destinations, and checks persisted values with `typeof()`. INTEGER, branch
TEXT, SQL NULL, BLOB bytes, and text matching the reserved type-tag prefix all
survive; the CASE result keeps conservative fallback metadata. Eight SQLite app
`ANY` contracts passed with strict Clippy and formatting. Other computed-
expression consumer paths remain open. See the
[CASE CSV evidence](../evidence/sqlite-case-any-csv-roundtrip-results-2026-10-04/manifest.json).

The CASE fixture now includes empty TEXT. CSV export/import keeps it distinct
from SQL NULL and restores the native storage class. XLSX refuses the empty
cell, reports the correct data row and column, and leaves a pre-existing
destination untouched with no temporary artifact left behind. See the [XLSX
refusal evidence](../evidence/sqlite-case-any-xlsx-refusal-results-2026-10-04/manifest.json).

## SQLite computed COALESCE STRICT ANY CSV round trip (2026-10-04)

An app-level result-file contract exports `coalesce(value, 'fallback')` over
STRICT `ANY`, imports the CSV into a typed destination and checks persisted
values with native `typeof()`. INTEGER, REAL, fallback TEXT for SQL NULL,
stored TEXT, BLOB bytes and tag-prefix-shaped text survive. The expression
retains fallback metadata. Nine SQLite app `ANY` contracts passed with strict
Clippy and formatting. Other computed-expression shapes, spreadsheet-app
re-import and installed editing remain open. See the
[COALESCE CSV evidence](../evidence/sqlite-coalesce-any-csv-roundtrip-results-2026-10-04/manifest.json)
and [COALESCE metadata evidence](../evidence/sqlite-coalesce-any-results-2026-10-04/manifest.json).
The same contract inspects JSON output and XLSX XML. JSON preserves numeric
INTEGER/REAL values separately from fallback/stored/tag-prefix strings and
BLOB's `\x00ff` text encoding. In XLSX, INTEGER and REAL are numeric cells;
fallback/stored/tag-prefix text and BLOB encoding are string cells, with no
formula cells. Spreadsheet-application re-import remains open. See the
[consumer evidence](../evidence/sqlite-coalesce-any-xlsx-results-2026-10-04/manifest.json).

## DuckDB enum keyed grid edit, 2026-10-03

A local DuckDB-backed app contract now parses a nonempty enum label through the
app parser and keyed-update builder, then verifies the saved value and native
`ENUM(...)` type. The fixture also preserves an empty enum label and SQL NULL as
distinct sibling values. An invalid label is rejected by DuckDB and the affected
row remains unchanged. The initial run corrected the test oracle: DuckDB reports
the declared ENUM type through `typeof(status)` even for a NULL value, while the
decoded cell remains `Value::Null`.

The grid parser keeps blank input as SQL NULL and accepts `''` as the explicit
input for an empty enum label; SQL single-quote escaping is also decoded before
the value reaches the keyed-update builder. The native contract checks both
paths, confirms the saved native ENUM type and sibling values, and still
refuses an invalid label without changing the keyed row. The focused contract,
all app-library tests with the optional DuckDB feature (444 passed, 20
ignored), Clippy, and the mapped `change-contracts` layer passed. Installed
GTK behavior remains open. See the
[DuckDB enum keyed-edit evidence](../evidence/duckdb-enum-keyed-results-2026-10-03/manifest.json).

## SQLite STRICT ANY CSV storage-class round trip (2026-10-03)

The first table-based round-trip contract exported a STRICT `ANY` column with
the generic CSV formatter and re-imported it through the app's native import
planner. It reproduced a loss: INTEGER `42`, REAL `-0.0`, and BLOB `00ff80` all
returned as TEXT. Numeric-looking TEXT also could not be distinguished from an
INTEGER, and empty TEXT from SQL NULL without an explicit marker. The final
successful native fixture uses REAL `1.5`; SQLite's existing bound-value path
refuses negative-zero REAL input because it cannot guarantee preserving that
bit, and this CSV change does not alter that refusal.

CSV values in declared `ANY` columns now use versioned `bookie:sqlite-any:v1:`
tags for INTEGER, REAL, TEXT and BLOB. Text payloads are tagged too, so text
that resembles a tag or a spreadsheet formula remains unambiguous. SQL NULL
uses the export's collision-free marker. SQLite ANY import decodes those tags,
keeps legacy untagged fields as TEXT, refuses malformed reserved tags, and
refuses a blank field when no explicit NULL marker separates it from SQL NULL.
The encoding is used by the column-aware CSV renderer, streamed file writer and
MCP's column-aware row writer.

The native app regression exports and imports a STRICT `ANY` table, then checks
`typeof(value)` plus the returned value for INTEGER, REAL, numeric-looking and
empty TEXT, SQL NULL, nonempty/empty BLOB, a tag-shaped text value and a
formula-shaped text value. A separate plan-level regression checks ambiguous
blank and malformed-tag refusal, legacy untagged text behavior and that the
target remains unchanged when planning refuses. Four core CSV/codec tests and
the two new app contracts pass alongside the existing three STRICT ANY grid
contracts. At that checkpoint, arbitrary SQLite query exports still reported
result-column type `NULL` for a declared `ANY` column, so they could not select
this type-aware encoding; see the follow-up below. Installed GTK behavior and
other output formats remain open.
See the [SQLite STRICT ANY CSV evidence](../evidence/sqlite-strict-any-csv-results-2026-10-03/manifest.json).

## SQLite STRICT ANY query-result CSV round trip (2026-10-03)

SQLx reports `NULL` for an unrecognized declared type such as SQLite `ANY`,
even when a query result column comes directly from a table. The SQLite driver
now uses SQLx's source-column origin to look up that column's declared type with
`pragma_table_xinfo` on the same connection. Ordinary, bound-parameter and
transaction queries recover `ANY`; the native test also confirms a computed
expression does not inherit the source column's type. If the catalog lookup is
unavailable, the query result remains usable with its original metadata.

The app CSV round trip now exports from `SELECT value FROM source` and uses the
query result's recovered metadata to write the storage-class tags. Import into a
separate STRICT `ANY` table preserves INTEGER, REAL, TEXT, BLOB, empty TEXT and
SQL NULL, verified with native `typeof()` and returned values. The app's five
focused STRICT ANY contracts, all 44 SQLite driver tests and SQLite driver
Clippy pass. See the
[query-result evidence](../evidence/sqlite-strict-any-query-csv-results-2026-10-03/manifest.json).

At that checkpoint, zero-row results had no column metadata in the row-based
conversion; see the follow-up below. Computed expressions and attached-schema
origins remain untyped when SQLx cannot supply a declared type. Other SQLite
consumers, output formats and installed GTK editing remain open.

## SQLite empty query result metadata (2026-10-03)

The SQLite driver now prepares each query before execution and retains its
result-column metadata even when it returns no rows. When SQLx reports an
unrecognized declared type as `NULL`, the driver resolves table-column origins
using schema-qualified `pragma_table_xinfo` on the same connection when the
source is unambiguous.
Ordinary, bound-parameter and transaction queries preserve declared STRICT
`ANY` metadata for both populated and empty results. Computed expressions do
not inherit `ANY` from their inputs. The app's empty query export keeps its
header, while the nonempty query-result CSV round trip continues to preserve
INTEGER, REAL, TEXT, BLOB, empty TEXT and SQL NULL with native `typeof()` proof.

The focused SQLite driver case, all 45 driver tests, five app STRICT ANY
contracts, Clippy, formatting and diff checks pass. See the
[empty-result evidence](../evidence/sqlite-query-empty-metadata-results-2026-10-03/manifest.json).
Mixed `CASE` and `COALESCE` expressions now have native `typeof()` contracts.
The CASE result covers INTEGER, SQL NULL and TEXT; COALESCE covers INTEGER,
fallback TEXT and stored TEXT. Both retain SQLx's `NULL` fallback metadata
instead of inheriting the input column's declared `ANY` type. CASE is checked
through a bound query; a separate zero-row expression query and transaction
query preserve fallback metadata. COALESCE is checked through ordinary and bound
queries. Direct-column queries continue recovering `ANY`.
All 26 SQLite integration tests pass with strict Clippy and formatting. See the
[CASE evidence](../evidence/sqlite-computed-any-results-2026-10-04/manifest.json) and
[COALESCE evidence](../evidence/sqlite-coalesce-any-results-2026-10-04/manifest.json).
Other computed expressions, formats, storage-class combinations and installed
GTK editing remain open. Attached-schema ambiguity is covered separately below.

## SQLite attached-schema query origins (2026-10-03)

The driver now resolves a flattened attached origin against SQLite's database
list and schema-qualified `pragma_table_xinfo`. It applies a declaration only
when exactly one main/attached catalog source matches, so a main table literally
named `aux.flexible` cannot be confused with `aux.flexible` in an attached
database. A native fixture verifies declared STRICT `ANY` metadata for an
unambiguous attached query and fallback metadata for both sources when names
collide; row values remain exact. All 45 driver tests and five app STRICT ANY
contracts pass, along with Clippy, formatting and diff checks. See the
[attached-origin evidence](../evidence/sqlite-attached-any-metadata-results-2026-10-03/manifest.json).

Other affinity/storage-class combinations, formats and installed GTK editing
remain open.

## SQLite computed expression over STRICT ANY (2026-10-04)

A mixed `CASE` expression over a STRICT `ANY` column returns an integer, SQL
NULL and text on separate rows. The driver leaves expression metadata at its
SQLx fallback `NULL` instead of claiming the input column's declared `ANY`
type; SQLite `typeof()` independently confirms `integer`, `null` and `text` for
the respective results. A bound query produces the same rows, while zero-row
query and transaction results preserve the unknown expression metadata without
inventing rows. The existing direct-column checks continue to recover `ANY`
for regular, bound and transaction queries. The focused case and all 25 SQLite
integration tests pass, along with strict Clippy and formatting. See the
[computed-expression evidence](../evidence/sqlite-computed-any-results-2026-10-04/manifest.json).

Other computed-expression shapes and installed consumer paths remain open.

## PostgreSQL enum structured-filter operator matrix (2026-10-03)

The ordinary-enum and domain-over-enum filter contracts now cover every shared
`FilterOp`: `=`, `<>`, `<`, `<=`, `>`, `>=`, Contains, StartsWith, EndsWith,
Like, NotLike, ILike, IsNull, IsNotNull, In, NotIn and Between. Each fixture
asserts exact row IDs and labels, with native enum type checks; the domain case
checks `pg_typeof(domain_column)::text`. Cases include literal label `NULL`, SQL
NULL, enum ordering and a Unicode label. Pattern filters exercise the enum to
text comparison path. Both focused PostgreSQL 16 Docker cases and both complete
10-test contract suites pass, as do PostgreSQL Clippy, formatting and diff
checks. See the
[operator matrix evidence](../evidence/postgres-enum-filter-matrix-results-2026-10-03/manifest.json).

This closes structured-filter operator coverage for these enum fixtures. Direct
query-parameter operator contexts, session/search_path combinations, deeper
domain chains and other enum/native value consumers remain open.

## PostgreSQL domain-over-enum query ordering parameters (2026-10-03)

The direct query comparison contract now exercises `<`, `<=`, `>` and `>=` on
a domain-over-enum column cast to its base enum. PostgreSQL infers the bound text
parameter as the qualified base enum for each operator; `pg_typeof($1)`,
`pg_typeof(status)` and per-row truth values (including SQL NULL propagation)
are asserted. The same fixture retains `=`, `<>`, both `BETWEEN` bounds, SQL NULL
parameter inference and the explicit SQLSTATE 42883 refusal for raw domain
equality. The focused PostgreSQL 16 case and all 10 domain contracts pass, along
with Clippy, formatting and diff checks. See the
[ordering-parameter evidence](../evidence/postgres-domain-enum-param-operator-results-2026-10-03/manifest.json).

Direct query parameters for list operators and other session/search_path
combinations remained untested at that checkpoint.

## PostgreSQL domain-over-enum query list parameters (2026-10-03)

The direct query comparison contract now checks `IN ($1, $2)` and
`NOT IN ($1, $2)` on a domain-over-enum column cast to its base enum. Both
parameters resolve to the qualified enum type, confirmed with `pg_typeof`, and
the exact per-row truth values retain SQL NULL propagation. The focused
PostgreSQL 16 case and all 10 domain contracts pass, as do Clippy, formatting
and diff checks. See the
[list-parameter evidence](../evidence/postgres-domain-enum-param-list-results-2026-10-03/manifest.json).

Other direct query contexts and session/search_path combinations remain open.

## PostgreSQL domain-over-enum NULL-safe distinctness parameters (2026-10-03)

The direct query contract now exercises `IS DISTINCT FROM` and
`IS NOT DISTINCT FROM` with both a text label and SQL NULL against a
domain-over-enum column cast to its base enum. PostgreSQL infers the parameter
as the qualified enum type, while `pg_typeof(status)` remains the domain; exact
per-row truth values prove NULL-safe semantics. All 10 domain contracts pass,
along with Clippy and formatting. See the
[NULL-safe distinctness evidence](../evidence/postgres-domain-enum-distinct-parameter-results-2026-10-03/manifest.json).

Other direct query contexts and session/search_path combinations remain open.

## PostgreSQL schema-shadowed enum list and range filters (2026-10-03)

The same-named enum fixture now checks structured `IN` and `BETWEEN` filters on
`enum_shadow_b.items` with the connection's `search_path` pointed at
`enum_shadow_a`. Every placeholder is built from schema-aware enum metadata;
native type and target/shadow row assertions confirm the operators do not
resolve through the colliding shadow type. The focused PostgreSQL 16 contract,
all 10 enum contracts, Clippy, formatting and diff checks pass. See the
[shadowed-filter matrix evidence](../evidence/postgres-shadowed-enum-filter-matrix-results-2026-10-03/manifest.json).

The other session/search_path and operator combinations remain open.

The same fixture also checks direct bound equality, `IN` and `BETWEEN` queries
on `enum_shadow_b.items` while `search_path` resolves the colliding
`enum_shadow_a.status_kind`. The target enum comparisons succeed, the returned
column retains its qualified native type, and the shadow row remains unchanged.
See the [direct parameter evidence](../evidence/postgres-shadowed-enum-parameter-results-2026-10-03/manifest.json).
Within a transaction, `SET LOCAL search_path TO enum_shadow_a` also leaves
`status = $1` against `enum_shadow_b.items` correctly inferred from the target
column, without explicitly casting the column.
The same fixture records that `pg_typeof($1)` alongside the enum comparison is
ambiguous to native `PREPARE` (`42P08`). The driver now preserves that error
when its text-typed fallback conflicts with the enum operator; an explicit
qualified parameter cast lets the diagnostic query report the target enum type.

## PostgreSQL schema-shadowed domain-over-enum parameters (2026-10-03)

The new PostgreSQL 16 fixture creates same-named enum and domain types in two
schemas, then points the role's `search_path` at the shadow schema while reading
the target table. Catalog metadata identifies the target domain's qualified
leaf enum, and a structured equality filter selects only the target row. Inside
a transaction with `SET LOCAL search_path` still resolving the shadow schema,
direct text equality and `IS NOT DISTINCT FROM` with SQL NULL select the expected
target rows. The shadow rows, domain type and sibling values remain unchanged.
The focused case and all 11 enum contracts pass; Clippy and formatting pass.
See the [shadowed domain-over-enum evidence](../evidence/postgres-shadowed-domain-enum-results-2026-10-03/manifest.json).

This proves the tested schema collision and operators. Other direct query
operators and session/search_path configurations remain open.

## PostgreSQL shadowed domain-over-enum direct operator matrix (2026-10-03)

The same two-schema fixture now checks direct bound `<>`, `<`, `<=`, `>`, `>=`,
`IN`, `NOT IN`, `BETWEEN`, `IS DISTINCT FROM` and `IS NOT DISTINCT FROM`
comparisons against the target domain's qualified leaf enum while the connection
and transaction-local `search_path` resolve the shadow schema. Each query checks
ordered target row IDs, labels, SQL NULL behavior and the target domain reported
by `pg_typeof(status)`; the shadow table and sibling values remain unchanged.
The focused PostgreSQL 16 case and all 11 enum contracts pass, as do Clippy and
formatting. See the [operator-matrix evidence](../evidence/postgres-shadowed-domain-enum-operator-results-2026-10-03/manifest.json).

Other schema/session configurations remain open; this case does not close B3.


### MySQL app temporal keyed-grid edit (2026-10-04)

The app parser turns edited TIME(6), DATETIME(6) and TIMESTAMP(6) text into
typed values, and the shared keyed-update builder persists all three through
the MySQL driver. Native reads assert the updated values, exact fractional
microseconds and the untouched sibling row. TIMESTAMP uses an explicit UTC
session and an epoch-microsecond oracle; parser tests pin its edit input as
`Value::DateTime`. The same live result exports exact CSV/JSON temporal text
and XLSX text cells, then imports from CSV back into MySQL with native equality.
The importer uses the
target driver to restore MySQL `timestamp(6)` RFC3339 text as
`Value::TimestampTz`, while generic/PostgreSQL naive timestamps remain
`Value::DateTime`. Installed grid interaction and other format consumers remain
open. See the [native app-edit and export/import evidence](../evidence/mysql-temporal-grid-edit-results-2026-10-04/manifest.json).

## PostgreSQL text array XML, HTML and Markdown file writers, 2026-10-04

A PostgreSQL 16 Docker contract exports one `text[]` containing a literal
`NULL`, SQL NULL, empty text, comma, quote, backslash, Unicode and hostile
markup through the XML, HTML and Markdown result-file writers. Native
`pg_typeof`, `array_to_json`, canonical array text and `array_send` bytes check
the type, element distinctions, content and bound-array round trip. The file
outputs preserve Unicode and escape the markup payload. The SQL file is replayed
into a target table and checked against the native text, JSON element and wire
oracles. XLSX assertions prove the value is a text cell containing the
distinct literal `NULL`, SQL NULL token, empty text, comma and markup payload.
This proves one array family through four presentation formats, SQL replay and
workbook text-cell output; other array families and spreadsheet-application
re-import remain open. The focused test, strict Clippy and format check passed. See the [evidence
manifest](../evidence/postgres-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL custom-enum 63-byte label boundary, 2026-10-04

A PostgreSQL 16 Docker fixture creates a custom enum with a 63-byte ASCII label
and a 21-character UTF-8 label that also occupies 63 bytes. `pg_enum` and
`octet_length` assert the exact catalog labels and byte lengths; `enum_range`
then returns both through the native driver with the declared enum type intact.
The multibyte label also survives `enum[]` projection with an SQL NULL element.
The decoded array text quotes this label while PostgreSQL's canonical `::text`
does not; native `array_to_json` and equal `array_send` bytes prove the result
remains semantically identical and bindable. The focused case, strict Clippy
and formatting pass. See the [evidence manifest](../evidence/postgres-enum-label-byte-boundary-results-2026-10-04/manifest.json).

## PostgreSQL overlength custom-enum label refusal, 2026-10-04

A PostgreSQL 16 Docker contract attempts to create an enum with a 64-byte
ASCII label, one byte over the server's 63-byte limit. PostgreSQL refuses the
DDL with SQLSTATE `42602`; `to_regtype` confirms that no type was left behind.
The focused case, strict Clippy and formatting pass. See the [evidence
manifest](../evidence/postgres-enum-overlength-refusal-results-2026-10-04/manifest.json).

## PostgreSQL custom-enum declared ordering, 2026-10-04

A PostgreSQL 16 fixture declares enum labels in `zulu`, `alpha`, `middle` order
so catalog order differs from lexical text order. `pg_enum.enumsortorder` is
the independent ordering oracle; a shuffled result containing duplicates and
SQL NULL confirms `ORDER BY label NULLS LAST` follows the native enum order,
preserves the custom enum result type, and leaves NULL last. The focused test,
strict Clippy and formatting pass. See the [evidence manifest](../evidence/postgres-enum-order-results-2026-10-04/manifest.json).

## PostgreSQL eight-domain-layer enum contract, 2026-10-04

The existing shadowed-`search_path` domain-over-enum oracle now also runs at
eight nested domains. It verifies enum-leaf metadata, schema-aware keyed and
draft writes (including SQL NULL), typed equality filtering, invalid-label
refusal, exact outer-domain type/value and an untouched SQL NULL sibling. The
focused test, strict Clippy and formatting pass. Deeper chains and other
enum/session combinations remain open; see the [evidence manifest](../evidence/postgres-eight-domain-results-2026-10-04/manifest.json).

## PostgreSQL nine-domain-layer enum contract, 2026-10-04

The same shadowed-`search_path` domain-over-enum contract now also runs at nine
nested domains. It verifies enum-leaf metadata, schema-aware keyed and draft
writes (including SQL NULL), typed equality filtering, invalid-label refusal,
exact outer-domain type/value and an untouched SQL NULL sibling. On the same
transaction backend, it changes `search_path` twice, reuses metadata fetched
before the changes for writes and filtering, and confirms rollback preserves
the original rows. All 13 PostgreSQL domain-contract tests, strict Clippy and
formatting pass. Greater depths and other enum/session
combinations remain open; see the [evidence manifest](../evidence/postgres-nine-domain-results-2026-10-04/manifest.json).

## PostgreSQL deep domain-over-enum resolver boundary, 2026-10-04

The shadowed-`search_path` domain-over-enum contract now runs at depths 6, 7,
8, 9, 10, 63 and 64. Enum-leaf metadata, schema-aware writes, typed filters,
safe invalid-label outcomes and same-backend session changes/rollback pass at
every depth. Raw inferred SQL NULL updates preserve the outer domain type
through 63 layers. SQLx's 64-step OID resolver cannot infer raw text or SQL NULL
parameters at 64 nested domains; BookieE reports both as explicit unsupported
operations instead of internal errors, and neither operation changes the row.
All 13 PostgreSQL domain-contract tests, strict Clippy and formatting pass.
Other domain depths and session configurations remain open; see the
[deep-domain evidence](../evidence/postgres-deep-domain-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum 257-layer boundary, 2026-10-04

A PostgreSQL 16 contract extends schema-aware enum-leaf metadata, keyed writes
and filters to 257 nested domains with a same-named enum first in
`search_path`. A transaction-level shadowed path still updates the outermost
domain correctly and preserves a SQL NULL sibling; rollback restores the
pre-transaction values. Raw inferred enum text stays an explicit unsupported
result at this depth. See the
[257-layer evidence](../evidence/postgres-domain-257-level-results-2026-10-04/manifest.json).

## PostgreSQL enum metadata after session search_path changes, 2026-10-04

A PostgreSQL 16 transaction changes ordinary session `search_path` twice on
the same backend, confirms the active schema each time, and then fetches and
updates an enum column whose qualified target schema differs from the final
shadow schema. Native type/value checks verify the target row changed and the
shadow row did not. The transaction rolls back its session changes. The focused
test, strict Clippy and formatting pass. See the [evidence manifest](../evidence/postgres-enum-session-search-path-results-2026-10-04/manifest.json).

## MySQL word-character delimiter boundary, 2026-10-04

An app-level parser regression uses `DELIMITER xyz` to terminate a stored
procedure at `ENDxyz`. The word delimiter is recognized at the end of the
`END` token; the same text inside a quoted body string does not terminate the
statement. Planner, script extraction, formatter and named-parameter extraction
agree on the routine followed by a trailing parameterized SELECT. MySQL's
reference documents delimiter strings and warns that a delimiter can occur
inside words; this case pins the lexer's word-character delimiter path. See the
[MySQL client delimiter documentation](https://dev.mysql.com/doc/refman/8.4/en/mysql-commands.html).
The focused app test, strict Clippy and formatting pass. See the [evidence
manifest](../evidence/mysql-word-delimiter-results-2026-10-04/manifest.json).

## MySQL malformed routine human policy decision, 2026-10-04

The malformed-routine parser regression now evaluates the same `Unparseable`
facts under both principals. Agents are denied with `fail_closed_unparseable`;
the default local human policy returns `RequireApproval`, and the explicit
`human_approve_unparseable = false` override returns the documented human allow
decision. This pins the policy decision only; the GTK approval interaction
is now exercised with a SQLite fixture: a complete unparseable procedure reaches
the dialog, and denial leaves data unchanged. The same GTK harness confirms
lexically malformed SQL is stopped by the editor planner before approval.
MySQL-backed dialog routing remains open. The focused app test, strict Clippy
and formatting pass. See the
[evidence manifest](../evidence/mysql-malformed-human-approval-results-2026-10-04/manifest.json).

## GTK approval dialog for unparseable human SQL, 2026-10-04

The full GTK safety harness runs the release binary under isolated D-Bus,
Xvfb and AT-SPI. A complete `CREATE PROCEDURE` classified `Unparseable` shows
the approval dialog with its class and SQL text; denying it leaves the database
unchanged. A separate unterminated SQL script displays the planner error and
does not open approval. All 29 GTK safety scenarios pass. The UI case uses a
SQLite fixture and does not prove approval routing through a MySQL-backed
connection. See the [evidence manifest](../evidence/gtk-unparseable-approval-results-2026-10-04/manifest.json).

## MySQL quoted multi-character delimiter consumer agreement, 2026-10-04

An app-level contract uses quoted `DELIMITER '_finish'` and `DELIMITER ';'`
directives around a procedure whose terminator is adjacent to `END`. The
planner, app splitter, formatter and named-parameter extractor agree on one
routine followed by a parameterized SELECT; delimiter-shaped and placeholder
text inside the quoted routine string remain part of the body. The MySQL client
supports quoted delimiter arguments; see the [client command documentation](https://dev.mysql.com/doc/refman/8.4/en/mysql-commands.html).
The focused app test, strict Clippy and formatting pass. See the [evidence
manifest](../evidence/mysql-quoted-delimiter-results-2026-10-04/manifest.json).

## SQLite NULLIF computed STRICT ANY result round trip, 2026-10-04

A `NULLIF(value, 'drop')` projection over STRICT `ANY` yields INTEGER, REAL,
TEXT, BLOB and SQL NULL rows while result metadata stays at its computed
fallback. A CSV export/import round trip preserves each runtime class, exact
BLOB bytes and a text value shaped like the reserved tag; native `typeof()` is
the oracle. The focused app test, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/sqlite-nullif-any-results-2026-10-04/manifest.json).

## SQLite MAX over computed STRICT ANY result round trip, 2026-10-04

Grouped `MAX(value)` projections over STRICT `ANY` return INTEGER, REAL, TEXT,
BLOB and SQL NULL from separate groups while result metadata remains the
computed fallback. Typed CSV export/import preserves each runtime class, exact
BLOB bytes and text matching the reserved tag; native `typeof()` checks both
source and restored cells. All 12 selected SQLite app contracts, strict Clippy
and formatting pass. See the [evidence manifest](../evidence/sqlite-max-any-results-2026-10-04/manifest.json).

## SQLite JSON extraction over STRICT ANY result round trip, 2026-10-04

One `json_extract(document, '$.v')` projection over STRICT `ANY` returns
INTEGER, REAL, TEXT and SQL NULL rows, including a 64-bit integer, a boolean
converted to INTEGER, an object and an array returned as text, JSON null, and a
missing path. Native `typeof()` and `json_type()` checks keep the extracted
storage class distinct from the source JSON kind; typed CSV round-trip restores
the carrier and records JSON null separately from a missing path. All 13
selected SQLite app contracts, strict Clippy and formatting pass. JSON export
keeps large integers numeric and preserves extracted strings; XLSX uses numeric
cells for numeric results and shared strings for text, with no formulas.
Spreadsheet-app re-import remains open. See the
[evidence manifest](../evidence/sqlite-json-extract-any-results-2026-10-04/manifest.json).

## SQLite SUM over computed STRICT ANY result round trip, 2026-10-04

Grouped `SUM(value)` over STRICT `ANY` returns INTEGER, REAL and SQL NULL
according to SQLite's input storage classes and coercion rules. Numeric text
contributes numerically; nonnumeric text and BLOB inputs produce REAL zero.
Typed CSV export/import preserves each result carrier, verified by native
`typeof()`. Adding `9223372036854775807` and `1` returns SQLite's integer
overflow error instead of a rounded value. All 14 selected SQLite app
contracts, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/sqlite-sum-any-results-2026-10-04/manifest.json).

## SQLite AVG over computed STRICT ANY result round trip, 2026-10-04

Grouped `AVG(value)` over STRICT `ANY` returns REAL for every non-NULL group,
including integer and numeric-text inputs; an all-NULL group returns SQL NULL.
Nonnumeric text and BLOB inputs yield REAL zero. A pair containing
`9223372036854775807` and `1` averages as REAL instead of raising SUM's integer
overflow. Typed CSV export/import preserves the computed values and runtime
classes, checked with native `typeof()`. All 15 selected SQLite app contracts,
strict Clippy and formatting pass. See the
[evidence manifest](../evidence/sqlite-avg-any-results-2026-10-04/manifest.json).

## SQLite arithmetic over computed STRICT ANY result round trip, 2026-10-04

The `value + 1`, `value / 2` and `value / 0` expressions over STRICT `ANY`
cover INTEGER, REAL, numeric TEXT, nonnumeric TEXT, BLOB and SQL NULL inputs.
SQLite coerces numeric text, treats nonnumeric text and BLOB as zero, promotes
integer overflow to REAL, truncates integer division, and returns SQL NULL for
division by zero. Typed CSV export/import restores each computed value and
runtime class, checked with native `typeof()`. All 16 selected SQLite app
contracts, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/sqlite-arithmetic-any-results-2026-10-04/manifest.json).

## PostgreSQL numeric array file-writer contract, 2026-10-04

A PostgreSQL 16 Docker contract exports a `numeric[]` containing a 40-digit
integer, high-scale decimal, scale-preserving `1.2300`, NaN, positive/negative
Infinity and SQL NULL. Native `array_to_json` and `array_send` oracles confirm
that the driver's quoted numeric elements remain semantically identical and
bindable. JSON, CSV and XLSX preserve the driver's exact text representation;
XLSX uses a string cell without a formula. Replayed SQL restores canonical
PostgreSQL array text, JSON elements and wire bytes. The focused test, strict
Clippy and formatting pass. See the [evidence manifest](../evidence/postgres-numeric-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL custom enum-array file-writer contract, 2026-10-04

A PostgreSQL 16 Docker contract exports a custom `enum[]` containing literal
`NULL`, empty text, Unicode, comma, quote, markup and SQL NULL. The server's
`array_to_json` and `array_send` oracles verify the driver's text after binding;
JSON, CSV and XLSX preserve that text, with XLSX using a string cell and
escaping markup. Replayed SQL restores native array text, JSON elements and
wire bytes. The focused test, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-enum-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum array file-writer contract, 2026-10-04

A PostgreSQL 16 Docker contract exports a domain-over-enum array containing
literal `NULL`, empty text, Unicode, comma, quote, markup, a formula-like label
and SQL NULL through JSON, CSV, XML, HTML, Markdown and XLSX. A qualified text
binding matches native `array_to_json` and `array_send` oracles. Replayed SQL
restores the domain-array type, JSON values and wire bytes. Strict PostgreSQL
Clippy and formatting pass; repository size guards report existing unrelated
violations. See the [evidence manifest](../evidence/postgres-domain-enum-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL custom enum-array CSV import contract, 2026-10-04

A PostgreSQL 16 Docker contract imports a custom `enum[]` from CSV with literal
`NULL`, empty text, Unicode, comma, quote, markup and SQL NULL labels. Catalog
metadata resolves the enum element type, and the insert plan uses a
schema-qualified array cast. Native `pg_typeof`, `array_to_json` and
`array_send` verify restored type, values and exact bytes; an existing sibling
row remains unchanged. The PostgreSQL array contract group, focused core tests,
strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-enum-array-csv-import-results-2026-10-04/manifest.json).

## PostgreSQL custom enum-array CSV shape and NULL contract, 2026-10-04

A PostgreSQL 16 Docker contract uses an explicit CSV null marker to distinguish
a SQL NULL array from an empty array and an array containing a SQL NULL element.
It also preserves a custom enum array with lower bound zero, a literal `NULL`
label, an empty label, and Unicode, plus a two-dimensional array. Native
`pg_typeof`, `array_dims`, `array_to_json` and `array_send` values match after
import, and an existing sibling row retains its wire bytes. All 16 PostgreSQL
array-contract tests, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-enum-array-csv-shapes-results-2026-10-04/manifest.json).

## PostgreSQL custom enum-array import under a shadowed search_path, 2026-10-04

A PostgreSQL 16 Docker contract creates same-named enum types in two schemas,
with the active transaction `search_path` selecting the shadow type. The
schema-aware CSV importer targets the table's enum array, whose label is not
accepted by the shadow type. The qualified cast succeeds, native type/value
checks pass and the sibling row remains unchanged. All 17 PostgreSQL
array-contract tests, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-shadowed-enum-array-import-results-2026-10-04/manifest.json).

## PostgreSQL custom enum-array grid edit contract, 2026-10-04

The app parser keeps a custom enum-array edit as exact text and the keyed
update builder applies its schema-qualified type cast. A PostgreSQL 16 Docker
case preserves literal `NULL`, empty text, Unicode, comma-containing labels
and SQL NULL elements against native type, dimensions, JSON and wire oracles.
An invalid label is refused without mutation and the sibling row retains its
wire bytes. All 18 PostgreSQL array-contract tests, the focused app-parser test,
strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-enum-array-grid-edit-results-2026-10-04/manifest.json).

The same grid path also distinguishes blank SQL NULL from the custom enum-array
literal `{}`: blank input stores a typed SQL NULL, while `{}` stores a non-NULL
empty array. The native PostgreSQL array contract group and app-parser test pass
([evidence](../evidence/postgres-enum-array-grid-null-results-2026-10-04/manifest.json)).

## PostgreSQL custom enum-array CSV default NULL marker, 2026-10-04

The default blank CSV marker now restores a whole custom enum array as SQL
NULL. PostgreSQL represents an empty array as `{}`, so it remains distinct;
arrays containing SQL NULL elements remain distinct as well. Scalar enum blank
cells still fail closed as ambiguous because an empty enum label is a valid
scalar value. The full core suite, PostgreSQL array contract group, strict
Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-enum-array-default-null-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum array CSV import, 2026-10-04

CSV import now recognizes a custom domain as the direct element type of a
PostgreSQL array and emits a schema-qualified cast to that domain array. A
PostgreSQL 16 contract preserves literal `NULL`, empty text, Unicode,
comma-containing labels and SQL NULL elements against native type, JSON and
wire-byte oracles. A domain CHECK rejects a forbidden label with SQLSTATE
23514 without inserting the row. The PostgreSQL enum and domain contract
groups, full core suite, strict Clippy and formatting pass. See the
[evidence manifest](../evidence/postgres-domain-enum-array-import-results-2026-10-04/manifest.json).

The same domain-over-enum array now has app-parser and live keyed-grid coverage.
Native array values and bytes survive valid edits; an invalid enum label trips
the domain CHECK and transaction rollback preserves the stored row. The full
domain contract group, focused app-parser test, strict Clippy and formatting
pass ([grid evidence](../evidence/postgres-domain-enum-array-grid-results-2026-10-04/manifest.json)).

A structured equality filter also binds this array as its qualified domain
array type and matches native values, JSON and wire bytes. The domain-contract
group, full core suite, strict Clippy and formatting pass ([filter evidence](../evidence/postgres-domain-enum-array-filter-results-2026-10-04/manifest.json)).

CSV import is also tested with a same-named domain in another schema placed
first in `search_path`. The generated insert still casts to the target table's
qualified domain-array type, preserves native type, JSON and wire bytes, and
leaves the sibling row intact ([shadowed-path evidence](../evidence/postgres-domain-enum-array-shadowed-import-results-2026-10-04/manifest.json)).

## PostgreSQL arrays of UUID domains, 2026-10-04

A PostgreSQL 16 regression first reproduced `Undecodable` for an array of a
domain over UUID, even though the equivalent UUID array is supported. The
binary decoder now validates the array header against the declared domain OID
and decodes elements using the recursively resolved base OID. NULL and empty
arrays remain distinct; binding and a keyed grid edit preserve native JSON and
wire bytes. A UUID rejected by the domain CHECK returns SQLSTATE 23514 and
leaves the edited row and its sibling unchanged. The full PostgreSQL
integration target, strict Clippy and formatting pass; repository size guards
retain unrelated existing violations. See the
[evidence manifest](../evidence/postgres-domain-uuid-array-results-2026-10-04/manifest.json).

## PostgreSQL domain arrays over text, numeric and timestamptz, 2026-10-04

A PostgreSQL 16 transaction projects arrays of domains over text, numeric and
timestamptz while the session timezone is Asia/Kathmandu. Qualified text
bindings reproduce the native array JSON and wire bytes, including empty and
literal `NULL` text, numeric scale, two instants in a DST fold, infinity and
NULL elements. The focused contract, strict Clippy and formatting pass. See the
[matrix evidence](../evidence/postgres-domain-array-family-results-2026-10-04/manifest.json).

## PostgreSQL timestamptz-array file-writer contract, 2026-10-04

A PostgreSQL 16 Docker contract exports a `timestamptz[]` containing two
distinct instants in the New York fall-back hour, a BC instant, positive and
negative infinity and SQL NULL. The server's `array_to_json` and `array_send`
oracles confirm both instants survive text binding; JSON, CSV and XLSX preserve
the driver text as a string, and replayed SQL restores native text, JSON values
and wire bytes. The entire PostgreSQL array contract group passed (13 tests),
along with strict Clippy and formatting. See the [evidence manifest](../evidence/postgres-timestamptz-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL interval-array file-writer contract under postgres_verbose, 2026-10-04

A PostgreSQL 16 Docker contract exports an `interval[]` with mixed-sign months,
days, fractional time and SQL NULL under transaction-local `IntervalStyle =
'postgres_verbose'`. Binding the driver's array text reproduces native
`array_to_json` and `array_send` results. JSON, CSV and XLSX preserve the text;
replayed SQL restores native text, JSON elements and wire bytes under the same
style. The rollback leaves the destination empty. All 14 array-contract tests,
strict Clippy and formatting pass. Other interval styles remain untested. See
the [evidence manifest](../evidence/postgres-interval-array-filewriter-results-2026-10-04/manifest.json).

## PostgreSQL enum-array Calc re-import, 2026-10-04

The custom `enum[]` workbook written by BookieE survives LibreOffice Calc
opening and saving as ODS, then reopening and saving as XLSX. The literal
`NULL` label, empty label, Unicode, comma, quote, markup and SQL NULL remain in
the same shared-string cell text. The native PostgreSQL writer test, pinned
LibreOffice 26.8.0.3 round trip and standard-library OOXML/ODS checker pass.
Other array shapes and spreadsheet applications remain open. See the
[evidence manifest](../evidence/postgres-enum-array-calc-reimport-results-2026-10-04/manifest.json).

## DuckDB literal NULL enum label grid edit, 2026-10-04

The DuckDB app grid path now edits a row to the unquoted literal label `NULL`
through the parser and keyed-update builder. Native `typeof`, text and null
predicate checks show that row remains an ENUM value while its untouched sibling
stays SQL NULL. The focused test and DuckDB-enabled app library suite pass, as
do strict Clippy and formatting. Other DuckDB type, consumer and configuration
cases plus installed editing remain open. See the [evidence manifest](../evidence/duckdb-enum-null-label-results-2026-10-04/manifest.json).

## DuckDB enum raw CSV round trip, 2026-10-04

A local DuckDB contract exports and re-imports enum labels through CSV using an
explicit collision-free null marker and raw-text mode. Empty text, literal
`NULL`, Unicode, a quoted label, formula-shaped labels and SQL NULL retain
their values and native `ENUM` type. An unrelated existing destination row
remains unchanged. Spreadsheet-safe mode prefixes `=1+1`, and its typed import
plan maps that text to the same label as `'=1+1`; the safe encoding is for
presentation, while raw CSV is required for lossless restore. The focused
contract, all-feature app library suite, strict Clippy and formatting pass.
Installed GTK editing remains open; see the [evidence manifest](../evidence/duckdb-enum-csv-roundtrip-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-bytea array edit with shadowed search_path, 2026-10-04

A PostgreSQL 16 contract adds a same-named `payload` domain to a shadow schema
with a one-byte limit, while the target domain permits four bytes. A keyed edit
runs in a transaction whose `search_path` resolves the stricter domain first.
The qualified target-domain array cast succeeds; native type, JSON and
`array_send` bytes match the target oracle, and the sibling row stays unchanged.
The focused Docker test, strict Clippy and formatting pass. Other domain-array
types, session/search_path combinations, enum boundaries and consumers remain
open in B3. See the [evidence manifest](../evidence/postgres-shadowed-domain-bytea-array-results-2026-10-04/manifest.json).

## PostgreSQL enum CSV quote and line-break round trip, 2026-10-04

A PostgreSQL 16 contract exports custom enum labels containing a double quote,
an embedded line break and a backslash through raw CSV, parses the multiline
records, then imports with the schema-aware enum cast and a collision-free SQL
NULL marker. A formula-shaped label remains raw for lossless import. All four
supported delimiters crossed with LF, CRLF and CR record endings pass (12
combinations), and format auto-detection identifies the right delimiter and
header for each one. Restored rows match exact text, UTF-8 bytes, native enum
type and SQL NULL. The focused test, strict Clippy and formatting pass. Other
session configurations and spreadsheet-specific import behavior remain open. See the
[evidence manifest](../evidence/postgres-enum-csv-quoted-lines-results-2026-10-04/manifest.json).

## PostgreSQL enum SQL replay across string-literal modes, 2026-10-04

A PostgreSQL 16 native contract exports an enum label containing literal `\n`
and an apostrophe, then replays the same generated SQL in transactions with
`standard_conforming_strings=on, backslash_quote=safe_encoding` and
`standard_conforming_strings=off, backslash_quote=off`. The label remains exact
text with the same native enum type in both configurations. PostgreSQL text with
backslashes now uses explicit `E''` syntax and doubles each backslash; ordinary
values retain regular quoted-literal output. The native focused tests, core and
app suites, strict Clippy and formatting pass. Other session settings and SQL
literal edge cases remain open. See the [evidence manifest](../evidence/postgres-enum-sql-literal-session-modes-results-2026-10-04/manifest.json).

## SQLite STRICT ANY formula-shaped text through Calc, 2026-10-04

The compound-result workbook and a direct table projection over SQLite STRICT
`ANY` both contain text `=1+1` and `'=1+1` alongside integer `42`, text `42` and
SQL NULL. The direct projection also retains the declared `ANY` result metadata.
The BookiE XLSX writer stores both formula-shaped values as shared strings
without formula elements. LibreOffice Calc 26.8.0.3 preserves their text kind
through ODS save and XLSX re-save; the numeric, text and blank cells retain their
prior kinds. The focused app regression, strict Clippy, formatting and
standard-library OOXML/ODS checker pass. Other spreadsheet applications and
workbook shapes remain unverified.
See the [evidence manifest](../evidence/sqlite-xlsx-calc-formula-text-results-2026-10-04/manifest.json).

## PostgreSQL bytea[] XLSX through Calc, 2026-10-04

A PostgreSQL `bytea[]` containing non-UTF-8 bytes, empty bytea and SQL NULL is
written as an XLSX string cell and survives LibreOffice Calc's ODS save and
XLSX re-save with identical array text. Native `pg_typeof`, `array_to_json`,
`array_send` and per-element hex checks establish the binary values, order,
empty element and SQL NULL. The standard-library OOXML/ODS checker confirms the
cell remains text and is not a formula. Other array families and spreadsheet
applications remain open. See the [evidence manifest](../evidence/postgres-bytea-array-calc-reimport-results-2026-10-04/manifest.json).

## SQLite computed BLOB cast through typed CSV, 2026-10-04

A SQLite expression casts STRICT `ANY` source values to BLOB, producing
computed bytes from INTEGER, REAL, TEXT and BLOB inputs while SQL NULL remains
NULL. The result's runtime class is `NULL` metadata, so the consumer relies on
per-row native `typeof()` and exact `hex()` oracles. JSON preserves the bytes
in escaped text and XLSX writes non-NULL computed BLOB results as shared
strings. Typed CSV import into a second STRICT `ANY` table preserves every
result byte and storage class, including empty BLOB and SQL NULL. The focused
contract, DuckDB-enabled app
library suite, strict Clippy and formatting pass. See the [evidence manifest](../evidence/sqlite-cast-blob-any-csv-results-2026-10-04/manifest.json).

## PostgreSQL custom enum with quoted identifiers, 2026-10-04

A PostgreSQL schema, enum type and table with spaces in their identifiers are
discovered with exact qualified enum metadata. A generated keyed update changes
only the target row; the native type remains the quoted schema/type name, and a
structured equality filter selects that row. The sibling row remains unchanged.
Identifiers containing embedded quotes and other session/search_path
combinations remain open in this first spaces-only case. A follow-up now embeds
double quotes in all three identifiers and confirms metadata, keyed update and
filter SQL escape them correctly while preserving the native type and sibling
row ([evidence](../evidence/postgres-enum-identifier-escaping-results-2026-10-04/manifest.json)).
See the [spaces-case manifest](../evidence/postgres-enum-quoted-identifiers-results-2026-10-04/manifest.json).

## PostgreSQL enum target under shadowed search_path, 2026-10-04

The quoted target enum and a same-named shadow enum have different labels; the
shadow type rejects the target-only `paused` value. The test role defaults its
`search_path` to the shadow schema before BookiE opens the pool. Metadata is
fetched for the target table, then the generated keyed update and structured
equality filter select the target enum. Native `pg_typeof` text and `regtype`
OID comparisons identify each type, while target siblings and the shadow row
remain unchanged. Other transaction/session path permutations remain open. See
the [evidence manifest](../evidence/postgres-enum-shadowed-quoted-search-path-results-2026-10-04/manifest.json).

## PostgreSQL numeric[] XLSX through Calc, 2026-10-04

A PostgreSQL `numeric[]` containing a 40-digit integer, high-scale decimal,
scale-preserving `1.2300`, NaN, both infinities and SQL NULL is exported as one
XLSX shared-string cell. LibreOffice Calc 26.8.0.3 saves the workbook as ODS,
then reopens and saves XLSX; Python standard-library OOXML/ODS checks confirm
the exact 122-character array text remains unchanged and no formula is added.
The focused Docker contract, strict Clippy, formatting and round-trip checker
pass. Other array families and spreadsheet applications remain open. See the
[evidence manifest](../evidence/postgres-numeric-array-calc-reimport-results-2026-10-04/manifest.json).

## PostgreSQL float8[] exact-value XLSX through Calc, 2026-10-04

A PostgreSQL `float8[]` contract covers an adjacent value, negative zero, the
minimum subnormal, NaN, both infinities and SQL NULL. `float8send` verifies the
negative-zero and subnormal bit patterns; rebinding the driver's text must
match PostgreSQL's `array_send` bytes. PostgreSQL `array_to_json` renders
negative zero as `0`, so the test does not use JSON as its sign-bit oracle. The
XLSX array cell survives LibreOffice Calc 26.8.0.3's ODS save and XLSX re-save
as identical 390-character text without formulas. The focused contract, strict
Clippy, formatting and OOXML/ODS checker pass. Other array families and
spreadsheet applications remain open. See the
[evidence manifest](../evidence/postgres-float8-array-calc-reimport-results-2026-10-04/manifest.json).

## SQL Server GO script with malformed quoted tail, 2026-10-04

A SQL Server script with one valid `GO` batch followed by an unterminated
quoted tail is rejected as a whole. The planner reports a diagnostic, execution
planning returns an error, named-parameter extraction keeps only the earlier
safe parameter, and formatting preserves the malformed tail and batch
delimiters. Policy classifies the script as unparseable/write and denies it to
an agent. The focused app regression and strict unit-only GTK+DuckDB values
runner pass; see the [evidence manifest](../evidence/mssql-malformed-go-tail-results-2026-10-04/manifest.json).

## MySQL unparseable routine approval through GTK, 2026-10-04

The GTK harness opens a real MySQL 8.0 connection and shows the exact
unparseable `CREATE PROCEDURE` class and SQL in the approval dialog. Denial
leaves no routine in `information_schema`; Allow Once creates a separate
routine, checked through the MySQL client. The first run exposed a production
gap: approved unparameterized DDL used the pooled query path, which sent it via
the prepared-statement protocol and MySQL rejected it. The existing explicit
session path already retried this specific server error through text protocol;
both paths now share that fallback. The retained pre-fix accessibility tree
shows the protocol error, and the post-fix GTK layer, strict unit-only values
tier, Clippy, formatting and repository guards pass. This local GTK/Xvfb case
does not qualify installed Wayland behavior or other dialects; see the
[evidence manifest](../evidence/mysql-gtk-unparseable-approval-results-2026-10-04/manifest.json).

## MySQL short `\d` delimiter directive, 2026-10-04

An editor consumer contract covers the parser-supported `\d //` shorthand
around a stored procedure and its `\d ;` reset. Whole-script planning keeps the
routine body together and preserves the following SELECT as a distinct
statement; named-parameter extraction does not expose a routine-body placeholder
and retains the later query parameter. Formatting preserves both directives,
and post-format planning and policy keep the same statement count and
unparseable/write routine classification. The focused app selector, strict
unit-only GTK+DuckDB values tier, Clippy and formatting pass. Other MySQL
delimiter forms remain open; see the
[evidence manifest](../evidence/mysql-short-delimiter-results-2026-10-04/manifest.json).

## ClickHouse malformed heredoc consumer contract, 2026-10-04

ClickHouse's shared SQL scanner now skips `$tag$...$tag$` heredocs, including
an unterminated body through end of input, matching the script lexer. Core
coverage proves placeholders inside closed and malformed bodies are hidden;
the app consumer contract checks planner diagnostics, whole-script execution
refusal, safe-prefix parameter extraction, malformed-tail retention through
formatting, and unparseable/write classification with fail-closed agent denial.
The initial contract failed because the generic scanner only recognized
PostgreSQL dollar quotes. The focused core and app selectors, strict unit-only
GTK+DuckDB values tier, Clippy, formatting and repository guards pass. See the
[evidence manifest](../evidence/clickhouse-malformed-heredoc-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum schema-aware operations at 258 layers, 2026-10-04

A PostgreSQL 16 Docker contract extends the deep domain-over-enum schema-aware
boundary from 257 to 258 layers. With a same-named shadow enum first in
`search_path`, catalog metadata still identifies the target enum leaf, a keyed
edit and equality filter preserve the target outer-domain type, and a SQL NULL
sibling remains unchanged. The adjacent 257- and 258-layer contracts pass,
along with PostgreSQL Clippy, formatting, file-size and ignored-test inventory
checks. Raw inferred text/NULL remains explicitly unsupported from 64 layers;
domain depths beyond 258 and additional enum/session parameter combinations
remain open. See the
[evidence manifest](../evidence/postgres-domain-258-level-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum schema-aware operations at 259 layers, 2026-10-04

The adjacent shadowed-search-path PostgreSQL 16 Docker contract now extends
schema-aware enum metadata, keyed edits and equality filters to 259 nested
domains. It confirms the target outer-domain type and preserves a SQL NULL
sibling while a same-named shadow enum leads `search_path`. The 258- and
259-layer cases pass; raw inferred text/NULL remains explicitly unsupported
from 64 layers, and greater domain depths and other session combinations remain
open. See the [evidence manifest](../evidence/postgres-domain-259-level-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum COALESCE parameters, 2026-10-04

A PostgreSQL 16 Docker contract tests `COALESCE(status, $1)` and
`COALESCE($1, status)` for text and SQL NULL. `pg_typeof` confirms PostgreSQL
infers the parameter and expression as the base enum while the source column
remains the outer domain; exact rows verify argument order and NULL behavior.
The first assertion expected the expression to retain the domain, but the
server's native common-type resolution selects the base enum. The corrected
contract pins that behavior without changing production code. The focused case
and all 16 domain contracts, PostgreSQL Clippy, formatting, file-size and
ignored-test inventory checks pass. See the
[evidence manifest](../evidence/postgres-domain-coalesce-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum array functions, 2026-10-04

A PostgreSQL 16 Docker contract covers inferred text and SQL NULL parameters in
`array_append(ARRAY[status], $1)` and `array_prepend($1, ARRAY[status])`. Exact
values are checked for ready, paused and SQL NULL source rows. `pg_typeof`
records the native distinction: the array constructor preserves `state_domain[]`,
parameter inference and function output use the base `state` enum and `state[]`,
and the source column remains `state_domain`. The entire domain contract group
passes (17 tests), with PostgreSQL Clippy, formatting, ignored-test inventory,
file-size and diff checks. See the
[evidence manifest](../evidence/postgres-domain-array-functions-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum `array_remove` parameter inference, 2026-10-04

A PostgreSQL 16 Docker contract covers inferred text and SQL NULL parameters in
`array_remove(ARRAY[status::state], $1)` when `status` is a domain over an enum.
An independently typed query supplies each output array; `pg_typeof` checks
that the parameter is the base enum and the result is the base enum array. Both
parameter forms pass in ready, paused and SQL NULL source rows. The case extends
the inferred array-function matrix without changing production binding code;
other function contexts remain open. See the [evidence manifest](../evidence/postgres-domain-enum-array-remove-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum `array_position` parameter inference, 2026-10-04

A PostgreSQL 16 Docker contract covers text and SQL NULL parameters to
`array_position(ARRAY[status::state], $1)` for a domain-over-enum column. It
compares returned positions with a separately executed typed native query and
checks that the parameter is the base enum and the result is `integer`. The SQL
NULL case confirms PostgreSQL matches a NULL array element; other inferred
array-function contexts remain open. See the [evidence manifest](../evidence/postgres-domain-enum-array-position-results-2026-10-04/manifest.json).

## PostgreSQL domain-over-enum `array_replace` parameter inference, 2026-10-04

A PostgreSQL 16 Docker contract covers both inferred parameters in
`array_replace(ARRAY[status::state], $1, $2)` for a domain-over-enum source. It
checks text replacement, NULL search, NULL replacement, and both parameters
NULL. Each result array is compared with a separately typed native query, and
`pg_typeof` verifies both parameters are the base enum and the result is the
base enum array. Other inferred function and operator contexts remain open. See
the [evidence manifest](../evidence/postgres-domain-enum-array-replace-results-2026-10-04/manifest.json).

## PostgreSQL inferred enum-array parameter in `ANY`, 2026-10-04

A PostgreSQL 16 Docker contract compares a domain-over-enum column cast to its
base enum against uncast `ANY($1)`. The inferred enum-array parameter is checked
with ordinary, empty, and NULL arrays; literal `NULL`, empty, quoted, comma,
and backslash labels; and a two-dimensional array with lower bounds 0 and 3.
Assertions compare `pg_typeof`, source-domain type, exact `array_send` bytes
against a native array, and SQLSTATE `22P02` for an invalid label. An array
whose declared bounds disagree with its contents returns `Unsupported` before
dispatch. This new inferred path encodes PostgreSQL's binary array protocol;
existing explicitly cast text parameters remain a separate path. The exact
regression and all 99 PostgreSQL value contracts pass in the GTK + DuckDB
value tier. See the [evidence manifest](../evidence/postgres-domain-enum-any-array-parameter-results-2026-10-04/manifest.json).

## PostgreSQL inferred enum-array operators, 2026-10-04

The same domain-over-enum source now exercises inferred enum-array parameters
through containment (`<@` and `@>`) and overlap (`&&`), placing the parameter on
both sides of each operator. Cases include ordinary and adversarial labels,
literal `NULL` versus SQL NULL, empty arrays, and native invalid-label errors.
For each valid input, an independently cast native array provides operator
results and `array_send` bytes; `pg_typeof($1)` and the source domain type are
also asserted. The complete Docker-backed PostgreSQL integration suite passes
129 tests. See the [evidence manifest](../evidence/postgres-domain-enum-array-operators-results-2026-10-04/manifest.json).

## PostgreSQL inferred enum-array operators under shadowed `search_path`, 2026-10-04

The containment/overlap operator matrix now places a same-named enum with a
different label in the first `search_path` schema and queries a qualified
domain-over-enum source from another schema. All four operand orientations
still infer the target enum-array type and match native literal-array results
and `array_send` bytes. Invalid target labels return SQLSTATE `22P02` in both
containment positions; savepoints isolate the expected server errors. The full
PostgreSQL integration suite passes 129 tests. See the [evidence manifest](../evidence/postgres-shadowed-enum-array-operator-results-2026-10-04/manifest.json).

## PostgreSQL inferred enum-array domain-depth boundary, 2026-10-04

An array containment query infers arrays whose elements are nested enum domains.
At 62 and 63 domain layers, text arrays and SQL NULL arrays preserve the exact
domain-array type and `array_send` bytes against native typed-array controls.
At 64 layers, text and SQL NULL return explicit unsupported results before
dispatch. Unlike scalar enum parameters, the array container participates in
the type resolver's depth budget. At depth 63, PostgreSQL itself returns
SQLSTATE `42883` for scalar equality against `ANY(domain_array)`; the regression
records this native operator-resolution refusal and uses array containment for
the parameter-boundary oracle. The full Docker-backed PostgreSQL integration
suite passes 130 tests. See the [evidence manifest](../evidence/postgres-inferred-enum-array-depth-results-2026-10-04/manifest.json).

## GTK + DuckDB value tier with enum-array operator/depth cases, 2026-10-04

At source revision `d76dddc35b2a477782cce4d83bbeaa81f7fc0ce2`, the selected
GTK + DuckDB value tier passes 297 contracts across all 11 suites, with no
missing suites. PostgreSQL contributes 101 contracts, including inferred
enum-array operators under shadowed `search_path` and the 62/63/64 domain-depth
boundary. The raw report and suite logs are retained in the
[evidence packet](../evidence/full-value-tier-enum-array-depth-results-2026-10-04/manifest.json).

## PostgreSQL inferred domain-over-enum `array_cat` parameter, 2026-10-04

`array_cat(ARRAY[status::base_enum], $1)` accepts inferred enum-array text and
SQL NULL parameters when `status` has a domain-over-enum type. The contract
preserves the enum array's native result values and `pg_typeof`
results for NULL elements, empty arrays, SQL NULL arrays, literal `NULL`, empty,
comma, quote and backslash labels. It also runs with a same-named shadow enum
first in `search_path`. Native explicit-array expressions provide the result
oracle. The focused contract passed; the PostgreSQL selected value suite is
recorded with the [evidence manifest](../evidence/postgres-domain-enum-array-cat-results-2026-10-04/manifest.json).


## PostgreSQL inferred domain-over-enum `array_positions` parameter, 2026-10-04

`array_positions(ARRAY[status::base_enum, ...], $1)` now infers a scalar enum
parameter for a domain-over-enum source. The native control and bound query
check repeated-value positions and PostgreSQL's NULL-element matching; the
bound parameter and integer-array result types are asserted. A same-named shadow
enum leads the transaction `search_path` to check schema resolution. See the
[evidence manifest](../evidence/postgres-domain-enum-array-positions-results-2026-10-04/manifest.json).

## GTK + DuckDB value tier with PostgreSQL enum `array_positions`, 2026-10-04

At source revision `3d612e10d7b2226e4f6204afb60635abe1eec79e`, the strict local
GTK + DuckDB value tier passed 304 selected contracts across all 11 suites,
including 106 PostgreSQL contracts and no missing suites. The PostgreSQL suite
includes the inferred enum `array_positions` contract under shadowed
`search_path`; the raw report and per-suite logs are retained in the
[evidence packet](../evidence/postgres-domain-enum-array-positions-results-2026-10-04/manifest.json).


## PostgreSQL domain-over-enum array comparison parameters, 2026-10-04

A Docker regression verifies that `labels = $1`, `<>`, `<`, `<=`, `>` and `>=`
infer the full domain-over-enum array type. Native PostgreSQL controls check
comparison results for duplicate rows, a non-default lower bound, an empty array,
a SQL NULL array and a NULL element. The target schema is absent from
`search_path`, where a same-named shadow enum leads. Parameter `array_send`
bytes match the native typed value. This records PostgreSQL array dimensional-bound
semantics as well as inferred parameter typing. See the
[evidence manifest](../evidence/postgres-domain-enum-array-equality-results-2026-10-04/manifest.json).


## PostgreSQL domain-over-enum array workbook re-import through Calc, 2026-10-04

The domain-over-enum array file-writer contract now accepts an artifact path so
the generated XLSX can be tested by a real spreadsheet application. LibreOffice
Calc 26.8.0.3 in the pinned Debian image opened the 50-code-point array-text
cell, saved ODS, then reopened and saved XLSX. The shared-string XLSX cells and
ODS string cell are identical; the text contains the literal `NULL`, empty label,
Unicode, comma, quote, markup, formula-shaped label and SQL NULL marker. The
[verification packet](../evidence/postgres-domain-enum-array-calc-reimport-results-2026-10-04/manifest.json) retains all artifacts and logs.


## GTK + DuckDB value tier with temporal array Calc cases, 2026-10-05

At source revision `ab529307ef667c0587413822727ec6978c2e9087`, the local GTK +
DuckDB value tier passed 316 selected tests across all 11 suites, with no
missing suites. PostgreSQL passed 115 contracts, including Calc boundary cases
for `date[]`, `timestamp[]`, `time[]` and `timetz[]`; MySQL/MariaDB passed 28.
Compilation reused 746 fresh artifacts and rebuilt one package. The runner
recorded `dirty: true`; `git status` showed only the two preserved B4 scratch
directories outside `linux/`. The report and all per-suite logs are retained in
the [evidence packet](../evidence/local-gtk-duckdb-value-tier-results-2026-10-05/manifest.json).


---

# Archived value-contracts narrative (2026-10-09 consolidation pass 2)

Moved from [value-contracts.md](../value-contracts.md). Live index is the Scope table and Run section on that page. Manifests under `evidence/` remain authoritative. Do not treat this archive as current completion.

## Intro case narratives

SQL Server `decimal(38,38)` values preserve signed `1e-38`, scaled zero,
native text and CSV round trips; values outside `rust_decimal`'s exact range
remain exact text. Non-NULL `sql_variant` values refuse scalar decoding while
SQL NULL and connection usability are retained. See the merged [PR #443](https://github.com/cozyGarage/BookiE/pull/443)
for native test and mutation evidence.

Recent PostgreSQL enum-function evidence covers both `enum_range(NULL::type)`
and bounded `enum_range(start, end)` semantics under a same-named leading
shadow type, plus `enum_first`/`enum_last` and scalar `min`/`max` results
([unbounded](../evidence/postgres-enum-range-shadowed-path-results-2026-10-05/manifest.json),
[bounded](../evidence/postgres-enum-range-bounds-shadowed-results-2026-10-05/manifest.json),
[first/last](../evidence/postgres-enum-first-last-shadowed-path-results-2026-10-05/manifest.json),
[min/max](../evidence/postgres-enum-min-max-shadowed-path-results-2026-10-05/manifest.json),
[same-session label addition](../evidence/postgres-enum-add-value-session-results-2026-10-05/manifest.json),
[same-session label rename](../evidence/postgres-enum-rename-value-session-results-2026-10-05/manifest.json),
[same-session type rename/schema move](../evidence/postgres-enum-type-rename-schema-move-results-2026-10-05/manifest.json)).

The October 6 strict GTK + DuckDB value tier passed 364 selected tests across
all 11 suites with no missing suites on clean source `cfc99dd1`; see the [complete run packet](../evidence/local-gtk-duckdb-value-tier-results-2026-10-06-cfc99dd1/manifest.json).

The PostgreSQL `timestamp[]` evidence now covers typed rebinding, canonical
CSV export and SQL replay across a `DateStyle` change, with native array JSON
and wire-byte checks plus sibling preservation
([rebind evidence](../evidence/postgres-timestamp-array-datestyle-results-2026-10-05/manifest.json),
[file-consumer evidence](../evidence/postgres-timestamp-array-file-consumers-dmy-results-2026-10-05/manifest.json)).

PostgreSQL `name[]` result decoding and session rebinding cover SQL NULL, empty
and literal `NULL`, escaped labels, Unicode and the 63-byte UTF-8 boundary,
checked against native `array_send` bytes in
`value_contract_arrays_preserve_elements_dimensions_and_exports`. Keyed grid
edits use the qualified built-in cast and preserve the sibling row in
`value_contract_array_grid_edit_preserves_array_elements`.
Typed CSV import of `name[]` uses the same value distinctions and checks the
restored native wire bytes in `value_contract_builtin_array_families_survive_typed_csv_insert`.

Copied INSERTs and SQL-file exports omit PostgreSQL and SQL Server identity
values so the destination generates a fresh key; MySQL keeps explicit
auto-increment values. PostgreSQL `GENERATED ALWAYS` and `BY DEFAULT` identities,
SQL Server `IDENTITY`, generated columns and identity-only tables are checked
against native rows in
`value_contract_postgres_copy_insert_regenerates_identity_values` and
`value_contract_server_owned_columns_and_identity_copy_inserts_use_defaults`.
The SQL export writer pins the same per-engine output in
`sql_export_uses_engine_generated_identity_values`. Explicit identity-value
preservation is not supported by these copy/export paths.

`value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers`
checks SQL Server identity, computed and rowversion columns across all four
consumers. Native metadata makes the grid edit gate reject these columns while
leaving a normal text column editable. CSV mapping includes hostile values for
server-owned fields, but the plan inserts only the writable note. Copy as SQL
omits owned fields, and SQL export replays into a second native table; SQL
Server generates fresh identities, computed values and rowversions there. The
test checks both target and source rows.

The same PostgreSQL keyed grid contract covers `oid[]` zero, the unsigned
32-bit maximum and SQL NULL, using native type/text/`array_send` equality and
sibling preservation in `value_contract_array_grid_edit_preserves_array_elements`.

The exact Rust Decimal positive/negative mantissa limit and 28-place scale now
have parser, parameter, PostgreSQL typed-binding and SQL-literal checks. Values
just outside the crate's range are rejected by explicit Decimal and grid input;
Auto retains wide integers as text rather than guessing their type
([evidence](../evidence/rust-decimal-boundary-contract-results-2026-10-06/manifest.json)).

PostgreSQL `xml[]` is covered through result decoding, inferred rebinding, keyed
grid writes and typed CSV restore. Native `pg_typeof`, array text and
`array_send` checks include XML fragments, SQL NULL, and a malformed XML
assignment refused with SQLSTATE `2200N` without changing either row
([validation on PR #118](https://github.com/cozyGarage/BookiE/pull/118#issuecomment-6027920545)).
JSON/CSV/XML/HTML/Markdown/XLSX/SQL file exports now also preserve exact array
text; SQL replay is checked against native JSON and wire bytes in
`value_contract_xml_array_file_exports_preserve_native_text`.

Custom composite arrays have a focused unsupported-value contract: native
PostgreSQL type, text, JSON and wire oracles confirm the value while SQL literal
and parameter paths refuse it without changing either row. Other custom array
families remain untested. The unlisted built-in `money[]` refusal covers
populated and NULL elements, native text/JSON/wire snapshots, literal/bind
refusal, and target/sibling preservation ([validation comment on PR #126](https://github.com/cozyGarage/BookiE/pull/126#issuecomment-6028961640)).
Built-in geometric arrays `point[]`, `line[]`, `lseg[]`, `box[]`, `path[]`,
`polygon[]`, and `circle[]` have the same visible-refusal, native oracle, and
write-preservation contract in
`value_contract_geometric_array_refusals_preserve_target_and_sibling_rows`.

A PostgreSQL domain whose base type is an array now preserves declared type metadata and non-default lower bounds through keyed edits; NULL, empty values, native JSON/wire bytes, and CHECK refusal are covered by a Docker-backed regression ([test](../../crates/drivers/postgres/tests/support/domain_array_type_contract.rs)).

PostgreSQL enum schema and type identifiers at the 63-byte catalog limit, including a multibyte final character, retain metadata and keyed edits; see the [Docker/local validation comment on PR #125](https://github.com/cozyGarage/BookiE/pull/125#issuecomment-6028822115).

## Case lookup prose (before Scope table)


SQLite's declared `ENUM` pseudo-type is covered as SQLite NUMERIC affinity:
native `typeof()`/`quote()` oracles distinguish text labels, numeric
INTEGER/REAL values, BLOB bytes and SQL NULL. Grid and typed CSV parsing also
preserve numeric affinity and refuse unsafe numeric inputs
([driver test](../../crates/drivers/sqlite/tests/runtime_typed_values.rs), [grid
test](../../crates/app/src/ui/browse_tab/tests.rs), [CSV
test](../../crates/core/src/import/cell/tests/sqlite_affinity.rs)). Declared `ANY`
retains its conservative text path because metadata omits STRICT table status.

Detailed native oracles, exact selectors and dated results are preserved in
[value-contract history](value-contract-history.md). Use these starting points,
then search that ledger/test for the specific type and consumer; one starting
point does not represent all support for that engine.

The shared scalar contract checks native UUID parameters and SQL-literal
round trips on PostgreSQL, SQL Server, ClickHouse and DuckDB. UUID-shaped text
and typed SQL NULL are controls; DuckDB uses its logical result type to preserve
`Value::Uuid`. A mixed DuckDB projection checks the UUID type map across columns
and rows, including UUID result metadata in populated and zero-row results
([scalar evidence](../evidence/value-uuid-multidriver-results-2026-10-05/manifest.json),
[mixed projection evidence](../evidence/duckdb-uuid-mixed-projection-results-2026-10-06/manifest.json)).

PostgreSQL `pg_lsn[]` preserves all 64 LSN bits, its non-default lower bound
and SQL NULL through result decoding, assignment-inferred binary binding,
keyed updates and typed CSV import. Native type/text/JSON and `array_send`
comparisons cover both successful paths and malformed-input refusal with target
and sibling rows unchanged ([evidence](../evidence/postgres-pg-lsn-array-results-2026-10-06/manifest.json)).

PostgreSQL `macaddr[]` preserves canonical six-octet values, SQL NULL and
non-default lower bounds through result decoding, inferred typed binding,
keyed updates and typed CSV import. Native type/text/JSON and `array_send`
comparisons cover malformed-input refusal and target/sibling preservation
([evidence](../evidence/postgres-macaddr-array-roundtrip-results-2026-10-06/manifest.json)).

PostgreSQL `macaddr8[]` preserves canonical eight-octet EUI-64 values, SQL NULL
and non-default lower bounds through result decoding, inferred typed binding,
keyed updates and typed CSV import. Native type/text/JSON and `array_send`
comparisons cover malformed-input refusal and target/sibling preservation
([evidence](../evidence/postgres-macaddr8-array-roundtrip-results-2026-10-06/manifest.json)).

PostgreSQL `inet[]` and `cidr[]` preserve IPv4/IPv6 host and network prefixes,
SQL NULL and non-default lower bounds through result decoding, inferred typed
binding, keyed updates and typed CSV import. Native type/text/JSON and
`array_send` comparisons cover malformed-prefix refusal, CIDR host-bit refusal
and target/sibling preservation
([evidence](../evidence/postgres-network-array-roundtrip-results-2026-10-06/manifest.json)).

A PostgreSQL `bytea[]` file-writer case preserves binary, empty and NULL array
elements across JSON, CSV, XLSX and SQL replay ([evidence](../evidence/postgres-bytea-array-filewriter-results-2026-10-04/manifest.json)).

PostgreSQL custom-enum parameters in either `UNION ALL` branch and either
`VALUES` row preserve the native enum type and wire text; ordinary, empty,
literal `NULL`, SQL NULL and invalid-label boundaries are checked, including
prepared-query reuse after a same-named shadow enum leads `search_path`
([evidence](../evidence/postgres-enum-union-values-inference-results-2026-10-05/manifest.json)).

A PostgreSQL Unicode schema/type name also survives enum metadata discovery,
keyed edits, draft inserts, and structured filters with native catalog
verification ([evidence](../evidence/postgres-enum-unicode-identifiers-results-2026-10-05/manifest.json)); typed CSV import preserves the enum type and empty/literal-`NULL`/SQL-NULL values with the sibling row unchanged
([CSV evidence](../evidence/postgres-enum-unicode-csv-import-results-2026-10-05/manifest.json)).

PostgreSQL `date[]`, `time[]`, `timestamp[]` and `timetz[]` app grid edits
preserve boundary values, native type and wire bytes through the parser and
keyed-update builder; invalid date-array input is refused without changing
either row ([evidence](../evidence/postgres-temporal-array-grid-edit-results-2026-10-05/manifest.json)).

PostgreSQL `smallint[]`, `integer[]` and `bigint[]` app grid edits preserve
signed endpoints, array lower bounds and SQL NULL, including `9007199254740993`
in `bigint[]`; overflowing smallint input is refused with both rows unchanged
([evidence](../evidence/postgres-integer-array-grid-edit-results-2026-10-05/manifest.json)).

The PostgreSQL `text[]` app grid path preserves SQL NULL, literal `NULL`, empty
text, delimiters, quotes, backslashes, Unicode, markup and formula-shaped text
through native JSON and wire checks; malformed input is rejected without row
changes ([evidence](../evidence/postgres-text-array-grid-edit-results-2026-10-05/manifest.json)).

A PostgreSQL custom `enum[]` XLSX cell preserves its NULL-label, empty, Unicode,
quoted and markup text through LibreOffice Calc's ODS/XLSX re-save
([evidence](../evidence/postgres-enum-array-calc-reimport-results-2026-10-04/manifest.json)).

The custom `enum[]` XLSX cell also survives Gnumeric's ODS/XLSX re-save with
the formula-shaped `=1+1` label, escaped values and SQL NULL preserved as text
([evidence](../evidence/postgres-enum-array-gnumeric-reimport-results-2026-10-05/manifest.json)).

The same enum-array workbook preserves that label as text through LibreOffice
Calc's XLSX/ODS/XLSX re-save, with the complete array string unchanged and no
formula cells ([evidence](../evidence/postgres-enum-array-formula-calc-reimport-results-2026-10-05/manifest.json)).

A scalar custom-enum XLSX workbook also survives Gnumeric's XLSX/ODS/XLSX
re-save: literal `NULL`, Unicode, markup and the `=1+1` label remain string
cells, SQL NULL stays blank, and no formula is created
([evidence](../evidence/postgres-enum-scalar-gnumeric-reimport-results-2026-10-05/manifest.json)).

PostgreSQL `date[]`, `timestamp[]`, `time[]` and `timetz[]` XLSX text cells
preserve their boundary values through Gnumeric's XLSX/ODS/XLSX re-save,
including BC and extended years, infinities, 24:00, maximum offsets and SQL
NULL ([evidence](../evidence/postgres-temporal-arrays-gnumeric-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `bytea[]` XLSX cell containing binary bytes, empty bytea and SQL
NULL also survives Calc's ODS/XLSX re-save with its string contents unchanged
([evidence](../evidence/postgres-bytea-array-calc-reimport-results-2026-10-04/manifest.json)).

A PostgreSQL `text[]` workbook preserves its 84-character array text, including
NULL distinctions, escaped quotes/backslashes, Unicode and hostile markup,
through LibreOffice Calc's XLSX-to-ODS-to-XLSX re-save. The shared/string cell
types remain text and no formulas are created
([evidence](../evidence/postgres-text-array-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `uuid[]` workbook preserves two UUIDs and SQL NULL through the same
Calc round trip as exact text. Native `array_send` bytes match after binding the
driver's quoted array text, and the re-saved cells remain strings without
formulas ([evidence](../evidence/postgres-uuid-array-calc-reimport-results-2026-10-05/manifest.json)).
The same native contract now checks JSON/CSV text exports and SQL-file replay;
re-import restores the native UUID[] type, JSON and wire bytes without changing
a pre-existing sibling row
([file-writer evidence](../evidence/postgres-uuid-array-filewriter-results-2026-10-05/manifest.json)).

A PostgreSQL `date[]` workbook preserves a BC date, year 10000, both date
infinities and SQL NULL through Calc's XLSX/ODS/XLSX round trip. The native
parameter rebind matches both `array_to_json` and `array_send`
([evidence](../evidence/postgres-date-array-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `timestamp[]` workbook preserves a BC timestamp, year 10000, the
maximum finite timestamp, both infinities and SQL NULL through Calc's
XLSX/ODS/XLSX round trip. The native parameter rebind matches both
`array_to_json` and `array_send`
([evidence](../evidence/postgres-timestamp-array-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `time[]` workbook preserves midnight, fractional microseconds,
23:59:59.999999, 24:00 and SQL NULL through Calc's XLSX/ODS/XLSX round trip.
The native parameter rebind matches both `array_to_json` and `array_send`
([evidence](../evidence/postgres-time-array-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `timetz[]` workbook preserves fractional wall times, the largest
positive and negative offsets, and SQL NULL through Calc's XLSX/ODS/XLSX round
trip. The native parameter rebind matches both `array_to_json` and `array_send`
([evidence](../evidence/postgres-timetz-array-calc-reimport-results-2026-10-05/manifest.json)).
The same native offsets also survive typed rebinding, JSON/CSV/XLSX output and
SQL replay after a session changes from `America/New_York` to UTC; SQL NULL and
a sibling array remain intact
([session/consumer evidence](../evidence/postgres-timetz-array-file-consumers-timezone-results-2026-10-05/manifest.json)).

A PostgreSQL `boolean[]` workbook preserves true, false and SQL NULL through
Calc's XLSX/ODS/XLSX round trip as a text cell. The native parameter rebind
matches both `array_to_json` and `array_send`
([evidence](../evidence/postgres-boolean-array-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `int8[]` workbook preserves a lower bound of zero, `i64::MIN`,
`9007199254740993`, `i64::MAX` and SQL NULL through Calc's XLSX/ODS/XLSX
round trip as text. Native `array_to_json` and `array_send` match after rebind
([evidence](../evidence/postgres-int8-array-calc-reimport-results-2026-10-05/manifest.json)).

PostgreSQL `smallint[]` and `integer[]` workbooks preserve signed boundaries,
values beyond single-precision exactness, SQL NULL, and lower bounds zero and
two through Calc's XLSX/ODS/XLSX round trip. Native `array_to_json` and
`array_send` match after rebinding
([evidence](../evidence/postgres-integer-arrays-calc-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `timestamptz[]` XLSX cell preserves both sides of a repeated hour,
a BC instant, infinities and SQL NULL through Calc's ODS/XLSX re-save as exact
text ([evidence](../evidence/postgres-timestamptz-array-calc-reimport-results-2026-10-04/manifest.json)).

A PostgreSQL `interval[]` XLSX cell preserves mixed-sign intervals,
microseconds, zero intervals and SQL NULL through Calc's ODS/XLSX re-save as
exact text ([evidence](../evidence/postgres-interval-array-calc-reimport-results-2026-10-04/manifest.json)).

A PostgreSQL `numeric[]` XLSX cell preserves wide precision, scale, NaN,
infinities and SQL NULL as one exact text value through Calc's ODS/XLSX re-save
([evidence](../evidence/postgres-numeric-array-calc-reimport-results-2026-10-04/manifest.json)).
The same workbook also survives Gnumeric's XLSX/ODS/XLSX re-save with the
40-digit integer, high-scale and scale-preserving decimals, NaN, infinities and
SQL NULL unchanged as a string cell without formulas
([Gnumeric evidence](../evidence/postgres-numeric-array-gnumeric-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL `float8[]` XLSX cell preserves an adjacent double, negative zero,
the minimum subnormal, NaN, infinities and SQL NULL as exact text through the
same Calc round trip ([evidence](../evidence/postgres-float8-array-calc-reimport-results-2026-10-04/manifest.json)).
The same `float8[]` workbook also survives Gnumeric's XLSX/ODS/XLSX re-save
with the adjacent double, negative zero, minimum subnormal, NaN, infinities and
SQL NULL unchanged as text and without formulas
([Gnumeric evidence](../evidence/postgres-float8-array-gnumeric-reimport-results-2026-10-05/manifest.json)).

A PostgreSQL array of a domain over `bytea` preserves binary, empty and NULL
elements and its declared type through decoding, qualified binding and keyed
edits; invalid values are refused without changing either row
([evidence](../evidence/postgres-domain-bytea-array-results-2026-10-04/manifest.json)).
Its keyed edit also stays bound to the target domain when `search_path` starts
with a same-named domain whose stricter CHECK rejects the value
([shadowed-path evidence](../evidence/postgres-shadowed-domain-bytea-array-results-2026-10-04/manifest.json)).

One compound SQLite STRICT `ANY` workbook now preserves numeric `42`, text
`42` and blank SQL NULL through a LibreOffice Calc import, ODS save and XLSX
re-save ([evidence](../evidence/sqlite-xlsx-calc-reimport-results-2026-10-04/manifest.json)).

ClickHouse `Enum8` and `Enum16` use label text in result values while retaining
the native enum type in result and table metadata. A Docker contract checks
parameter writes, `NULL` label versus SQL NULL, Unicode and quoted labels,
empty-string labels versus SQL NULL, CSV import with an explicit collision-free
null marker, and Copy as SQL replay against the native server
([test](../../crates/drivers/clickhouse/tests/support/enum_values.rs)).
A Docker-backed app grid contract edits nullable Enum8/Enum16 labels against
native type and signed-code oracles. It accepts quoted empty, literal `NULL`
and apostrophe-bearing labels, keeps blank input as SQL NULL, and proves an
undeclared label leaves all rows unchanged
([test](../../crates/app/tests/support/clickhouse_enum_contract.rs)).
Nested `Array(Enum8)`, `Array(Nullable(Enum8))`, `Array(Enum16)`,
`Array(Nullable(Enum16))`, `Tuple(Enum8, Nullable(Enum8), Enum8)` and
`Tuple(Enum16, Nullable(Enum16), Enum16)` use native `toJSONString` as the
value oracle and check JSON/CSV/XLSX export plus refusal by type-less SQL,
binding and keyed grid writes. Tuple shapes include nullable values and a
literal `NULL` label; nullable shapes distinguish SQL NULL from that label
([test](../../crates/drivers/clickhouse/tests/support/nested_values.rs)).

The compound-result and direct table-projection XLSX workbooks both keep `=1+1`
and `'=1+1` as text through the Calc ODS/XLSX round trip, without creating
formulas; other spreadsheet applications and workbook shapes remain unverified
([formula-text evidence](../evidence/sqlite-xlsx-calc-formula-text-results-2026-10-04/manifest.json)).

## Case lookup prose (after Scope table)


Additional case packets retained from the October 5 B3 work:

- MySQL/MariaDB: [`EMPTY_STRING_IS_NULL` enum CSV restore](../evidence/mariadb-empty-enum-empty-string-is-null-results-2026-10-05/manifest.json), [combined SQL modes](../evidence/mariadb-empty-enum-set-combined-mode-results-2026-10-05/manifest.json), [collated ENUM labels](../evidence/mysql-mariadb-enum-collation-results-2026-10-05/manifest.json), [binary ENUM](../evidence/mysql-binary-enum-collation-results-2026-10-05/manifest.json), [binary SET](../evidence/mysql-binary-set-collation-results-2026-10-05/manifest.json), [Latin-1 ENUM/SET](../evidence/mysql-latin1-enum-set-collation-results-2026-10-05/manifest.json), and [executable-comment policy](../evidence/mysql-executable-comment-policy-results-2026-10-05/manifest.json).
- PostgreSQL: [maximum UTF-8 enum-array label](../evidence/postgres-enum-array-max-label-results-2026-10-05/manifest.json), [enum-array boundary whitespace](../evidence/postgres-enum-array-whitespace-label-results-2026-10-05/manifest.json), [malformed dollar-quote consumers](../evidence/postgres-malformed-dollar-quote-consumers-results-2026-10-05/manifest.json), [domain depth 260](../evidence/postgres-domain-260-level-results-2026-10-05/manifest.json), [domain depth 300](../evidence/postgres-domain-300-level-results-2026-10-05/manifest.json), [enum label append](../evidence/postgres-enum-add-value-default-append-results-2026-10-05/manifest.json), [enum label positions](../evidence/postgres-enum-add-value-positions-results-2026-10-05/manifest.json), [ordered enum array aggregate](../evidence/postgres-enum-array-agg-results-2026-10-05/manifest.json), [enum-array `unnest` inference](../evidence/postgres-enum-array-unnest-inference-results-2026-10-05/manifest.json), [cross-session append](../evidence/postgres-enum-cross-session-add-after-results-2026-10-05/manifest.json), [cross-session catalog changes](../evidence/postgres-enum-cross-session-catalog-results-2026-10-05/manifest.json), [cross-session type move](../evidence/postgres-enum-cross-session-type-move-results-2026-10-05/manifest.json), [CSV shadow path](../evidence/postgres-enum-csv-shadow-search-path-results-2026-10-05/manifest.json), [quoted identifier shadow path](../evidence/postgres-enum-quoted-shadow-path-results-2026-10-05/manifest.json), [`float4[]` grid edit](evidence/postgres-float4-array-grid-edit-results-2026-10-05/manifest.json), [`interval[]` grid edit](evidence/postgres-interval-array-grid-edit-results-2026-10-05/manifest.json), and [`interval[]` style transition](evidence/postgres-interval-array-style-transition-results-2026-10-05/manifest.json).
- SQLite: [declared type and runtime-affinity mismatches](../evidence/sqlite-declared-affinity-results-2026-10-05/manifest.json) and [expression-column UTF-8 BLOB values](../evidence/sqlite-utf8-blob-result-results-2026-10-05/manifest.json).

PostgreSQL domain-over-enum CASE parameter inference now has a native contract
for both result branches under a shadowed `search_path`, including empty and
literal `NULL` labels distinct from SQL NULL
([evidence](../evidence/postgres-domain-case-shadowed-parameter-results-2026-10-05/manifest.json)).
The domain-over-enum `COALESCE` parameter contract now compares both argument
positions against native casts under that shadowed path, with empty, literal
`NULL`, SQL NULL and invalid shadow-only labels
([evidence](../evidence/postgres-domain-coalesce-shadowed-results-2026-10-05/manifest.json)).
Ordinary enum `COALESCE`, `NULLIF`, `GREATEST` and `LEAST` parameter inference is
also checked against native target-enum casts after warming metadata and
switching to a same-named shadow `search_path` on the same backend, for
empty/literal-`NULL` labels, SQL NULL and invalid shadow-only labels
([evidence](../evidence/postgres-shadowed-enum-parameter-context-results-2026-10-05/manifest.json)).
Integer and boolean parameters remain their native types and are refused by
PostgreSQL in enum comparisons and updates; the same fixture verifies the
target rows remain unchanged.

MySQL/MariaDB typed CSV import now also preserves an empty VARCHAR under
`EMPTY_STRING_IS_NULL`, separately from SQL NULL, with native text-byte
comparison on both CSV and SQL replay
([evidence](../evidence/mariadb-empty-varchar-import-empty-string-mode-results-2026-10-05/manifest.json)).

PostgreSQL domain-over-enum arrays now also have a bound text-parameter contract
for literal `NULL`, empty text, Unicode, comma-containing labels and SQL NULL,
verified against native `array_send` bytes ([parameter evidence](../evidence/postgres-domain-enum-array-parameter-results-2026-10-04/manifest.json)); a separate 2×2 parameter case preserves lower bounds 0 and 3 ([bounds evidence](../evidence/postgres-domain-enum-array-bounds-results-2026-10-04/manifest.json)).
CSV import now preserves the domain element type and enforces its CHECK constraints ([import evidence](../evidence/postgres-domain-enum-array-import-results-2026-10-04/manifest.json)).
It also resolves the target schema when `search_path` contains a same-named shadow domain ([shadowed-path import evidence](../evidence/postgres-domain-enum-array-shadowed-import-results-2026-10-04/manifest.json)).
The app parser and keyed grid edit use the same qualified domain-array cast; invalid values roll back without changing the row ([grid evidence](../evidence/postgres-domain-enum-array-grid-results-2026-10-04/manifest.json)).
Structured equality filters use the qualified domain-array type and match native array values ([filter evidence](../evidence/postgres-domain-enum-array-filter-results-2026-10-04/manifest.json)).
JSON, CSV, XML, HTML, Markdown and XLSX exports preserve domain-over-enum array text, and SQL replay restores the native type, JSON values and array wire bytes ([file-writer evidence](../evidence/postgres-domain-enum-array-filewriter-results-2026-10-04/manifest.json)). Its XLSX string cell also survives LibreOffice Calc ODS/XLSX re-import with exact text ([evidence](../evidence/postgres-domain-enum-array-calc-reimport-results-2026-10-04/manifest.json)).
The same workbook's formula-shaped enum label and escaped array text also survive Gnumeric's XLSX/ODS/XLSX re-save unchanged
([Gnumeric evidence](../evidence/postgres-domain-enum-array-gnumeric-reimport-results-2026-10-05/manifest.json)).
A separate PostgreSQL custom `enum[]` workbook preserves literal `NULL`, empty,
Unicode, escaped, formula-shaped and SQL NULL elements through Gnumeric's
XLSX/ODS/XLSX re-save ([evidence](../evidence/postgres-enum-array-gnumeric-reimport-results-2026-10-06/manifest.json)).
LibreOffice Calc also preserves that custom `enum[]` workbook through its
XLSX/ODS/XLSX re-save ([evidence](../evidence/postgres-enum-array-calc-reimport-results-2026-10-06/manifest.json)).
A separate `enum[]` case preserves a 2×6 array with non-default bounds, empty
and literal-`NULL` labels, a SQL NULL element, and formula-shaped text through
Calc and Gnumeric XLSX/ODS/XLSX re-saves. Native type, dimensions, JSON, wire
bytes, typed rebinding and SQL replay match PostgreSQL
([Calc evidence](../evidence/postgres-enum-array-shapes-calc-results-2026-10-06/manifest.json),
[Gnumeric evidence](../evidence/postgres-enum-array-shapes-gnumeric-results-2026-10-06/manifest.json)).
A UUID-domain array now decodes using its base OID and preserves NULL versus empty arrays, bound round trips, keyed edits, domain CHECK refusal and sibling rows ([UUID-domain array evidence](../evidence/postgres-domain-uuid-array-results-2026-10-04/manifest.json)).
Domain arrays over text, numeric and timestamptz also preserve NULL elements through qualified binding under an Asia/Kathmandu session, checked against native JSON and wire bytes ([base-type matrix evidence](../evidence/postgres-domain-array-family-results-2026-10-04/manifest.json)).

The PostgreSQL shadowed-search-path enum/domain write case now covers six
through ten levels, plus 63, 64, 65, 128, 129, 256, 257, 258 and 259 levels. Raw inferred text and SQL
NULL parameters work through 63 levels; at 64 or more levels they return
explicit unsupported results, including after schema-aware work warms the
same-backend transaction. Schema-aware writes and filters pass through 259
levels ([259-level evidence](../evidence/postgres-domain-259-level-results-2026-10-04/manifest.json),
[258-level evidence](../evidence/postgres-domain-258-level-results-2026-10-04/manifest.json),
[257-level evidence](../evidence/postgres-domain-257-level-results-2026-10-04/manifest.json)); see the [deep-domain
boundary evidence](../evidence/postgres-deep-domain-results-2026-10-04/manifest.json),
[129/256-level follow-up](../evidence/postgres-deep-domain-followup-results-2026-10-04/manifest.json),
[six/seven-level evidence](../evidence/postgres-seven-domain-results-2026-10-04/manifest.json),
[eight-level evidence](../evidence/postgres-eight-domain-results-2026-10-04/manifest.json)
and [nine-level evidence](../evidence/postgres-nine-domain-results-2026-10-04/manifest.json).

Inferred enum-array parameters also preserve type and wire bytes with 62- and
63-layer enum-domain elements. Text and SQL NULL array parameters at 64 layers
return an explicit unsupported result; the array container consumes part of
the type resolver's depth budget ([evidence](../evidence/postgres-inferred-enum-array-depth-results-2026-10-04/manifest.json)).
PostgreSQL's scalar `= ANY(domain_array)` operator lookup itself returns
`42883` at depth 63; that native refusal is recorded separately from the
working containment bind path.

PostgreSQL domain-over-enum `COALESCE` now has parameter inference coverage in
both argument positions for text and SQL NULL; the base-enum result and outer
domain source type are independently checked
([evidence](../evidence/postgres-domain-coalesce-results-2026-10-04/manifest.json)).
A companion `array_append`/`array_prepend` contract checks inferred text/SQL NULL
parameters and domain-array versus base-enum-array types
([evidence](../evidence/postgres-domain-array-functions-results-2026-10-04/manifest.json)).

An uncast `ANY($1)` predicate now infers an enum-array parameter when comparing
against a domain-over-enum column cast to its base enum. The contract checks
scalar and multidimensional arrays, nondefault lower bounds, quoted and escaped
labels, empty text, literal `NULL` versus SQL NULL, empty/NULL arrays, native
type and wire-byte identity, invalid-label SQLSTATE, and refusal before dispatch
for inconsistent array bounds ([evidence](../evidence/postgres-domain-enum-any-array-parameter-results-2026-10-04/manifest.json)).
This establishes this `ANY` context only; other implicit enum-array parameter
contexts remain open.

Follow-up coverage checks inferred enum arrays in containment (`<@`, `@>`) and
overlap (`&&`) with the parameter on either side. Native literal-array query
results, `pg_typeof`, source-domain type and `array_send` bytes agree across
NULL, empty and adversarial enum labels; invalid labels preserve SQLSTATE
`22P02` ([integration evidence](../evidence/postgres-domain-enum-array-operators-results-2026-10-04/manifest.json)).
The same four operator forms also pass with a same-named shadow enum first in
`search_path`, while qualified target type and wire-byte oracles remain exact
([shadowed-path evidence](../evidence/postgres-shadowed-enum-array-operator-results-2026-10-04/manifest.json)).

A PostgreSQL 16 transaction also changes ordinary session `search_path` twice
on one backend, then verifies target-schema enum metadata and keyed-write safety
under the final shadowed path ([session evidence](../evidence/postgres-enum-session-search-path-results-2026-10-04/manifest.json)).

Quoted schema/type identifiers containing spaces and embedded quotes now have
metadata, keyed-edit, draft-insert and filter coverage ([evidence](../evidence/postgres-quoted-enum-identifiers-results-2026-10-04/manifest.json)).
Their CSV-import path also preserves the qualified enum type under a
transaction-local shadowed `search_path`, keeps SQL NULL distinct from the
literal `NULL`, and leaves the same-named shadow target unchanged
([evidence](../evidence/postgres-enum-quoted-csv-shadow-results-2026-10-06/manifest.json)).

PostgreSQL custom-enum scalar and array labels at 63 bytes are verified for
ASCII and three-byte UTF-8 text, and a 64-byte label is refused without leaving
a type behind ([accepted boundary](../evidence/postgres-enum-label-byte-boundary-results-2026-10-04/manifest.json), [refusal evidence](../evidence/postgres-enum-overlength-refusal-results-2026-10-04/manifest.json)).
Native enum ordering also follows declaration order rather than lexical text sorting ([ordering evidence](../evidence/postgres-enum-order-results-2026-10-04/manifest.json)).

Raw PostgreSQL enum CSV export, parsing and schema-aware typed import also
preserve labels containing double quotes, embedded line breaks and backslashes,
along with formula-shaped text and SQL NULL across all four supported delimiters
and LF/CRLF/CR record endings. Import format auto-detection identifies every
combination; restored UTF-8 bytes and native enum type are checked independently
([evidence](../evidence/postgres-enum-csv-quoted-lines-results-2026-10-04/manifest.json)).

Separate PostgreSQL expression contexts now infer text and SQL NULL enum
parameters in `COALESCE` and `array_append` ([evidence](../evidence/postgres-enum-expression-parameter-results-2026-10-04/manifest.json)). A `NULLIF(enum_column, $1)` follow-up checks inferred type, NULL/match behavior and invalid-label refusal ([evidence](../evidence/postgres-enum-nullif-parameter-results-2026-10-04/manifest.json)). A domain-over-enum case records the raw `42883` refusal and passing qualified base-enum cast control under a shadowed `search_path` ([evidence](../evidence/postgres-domain-nullif-parameter-results-2026-10-04/manifest.json)).

Inferred text and SQL NULL parameters to PostgreSQL `array_remove` now have
domain-over-enum coverage against explicitly typed native-query results, with
parameter and result enum types checked independently
([evidence](../evidence/postgres-domain-enum-array-remove-results-2026-10-04/manifest.json)).
The corresponding `array_position` case checks native position results and
confirms that a SQL NULL parameter matches a NULL array element
([evidence](../evidence/postgres-domain-enum-array-position-results-2026-10-04/manifest.json)).
`array_replace` exercises two inferred parameters together for text, SQL NULL,
and their search/replacement combinations, with native result and enum-type
oracles ([evidence](../evidence/postgres-domain-enum-array-replace-results-2026-10-04/manifest.json)).
The same function now preserves both parameter types under a same-named shadow
enum in `search_path`; native results and wire bytes match, and labels found only
in the shadow are refused in either slot ([evidence](../evidence/postgres-domain-enum-array-replace-shadowed-results-2026-10-05/manifest.json)).
`array_position($1, enum_value)`, `array_remove($1, enum_value)`,
`array_append($1, enum_value)` and `array_prepend(enum_value, $1)` now cover
inference of the array parameter itself, including lower-bound arrays, empty and
NULL arrays, NULL elements, literal `NULL`, and shadow-only label refusal
([evidence](../evidence/postgres-domain-enum-array-input-functions-shadowed-results-2026-10-05/manifest.json)).
`array_append` and `array_prepend` now also preserve inferred target-enum binding
when a same-named shadow enum leads transaction `search_path`; the contract
checks native typed results, `pg_typeof`, result bytes, literal `NULL` versus
SQL NULL and invalid-label refusal ([evidence](../evidence/postgres-domain-enum-array-functions-shadowed-results-2026-10-04/manifest.json)).

PostgreSQL custom-enum SQL export now preserves a label containing literal `\n`
when replayed with all four `standard_conforming_strings` and `backslash_quote`
combinations (`on/safe_encoding`, `on/off`, `off/off`, `off/on`); the writer uses
an explicit escape string and native type/text checks verify each result
([initial evidence](../evidence/postgres-enum-sql-literal-session-modes-results-2026-10-04/manifest.json),
[full setting matrix](../evidence/postgres-enum-sql-literal-session-modes-full-results-2026-10-05/manifest.json)).

One PostgreSQL `text[]` case now checks XML, HTML, Markdown and XLSX output plus
replayed SQL against native array text, JSON elements and wire bytes; see the
[array file-writer evidence](../evidence/postgres-array-filewriter-results-2026-10-04/manifest.json).

A `numeric[]` file-writer contract checks high precision, scale, NaN, infinities
and SQL NULL through JSON, CSV, XLSX and replayed SQL. Native JSON and wire
oracles confirm that the driver's quoted element text remains bindable ([evidence](../evidence/postgres-numeric-array-filewriter-results-2026-10-04/manifest.json)).

A custom enum-array file-writer contract preserves empty text, literal `NULL`,
Unicode, comma, quote, markup and SQL NULL through JSON, CSV, XLSX and replayed
SQL. Native `array_to_json` and `array_send` checks verify bound and restored
values ([evidence](../evidence/postgres-enum-array-filewriter-results-2026-10-04/manifest.json)).
The SQL replay also preserves a backslash label under all four
`standard_conforming_strings`/`backslash_quote` combinations, with native
array text, JSON, wire-byte and sibling-row checks
([mode evidence](../evidence/postgres-enum-array-sql-mode-results-2026-10-05/manifest.json)).
Custom enum-array CSV import now uses a schema-qualified array cast and verifies
native type, values and sibling-row bytes ([import evidence](../evidence/postgres-enum-array-csv-import-results-2026-10-04/manifest.json)).
An explicit null marker also preserves NULL arrays, empty arrays, SQL NULL
elements, lower bounds and two-dimensional shape ([shape evidence](../evidence/postgres-enum-array-csv-shapes-results-2026-10-04/manifest.json)).
The target enum remains correct when a same-named type shadows it in the active
`search_path` ([shadowed-path evidence](../evidence/postgres-shadowed-enum-array-import-results-2026-10-04/manifest.json)).
The app parser and live keyed edit now preserve custom enum-array labels and
refuse invalid labels without mutation ([grid-edit evidence](../evidence/postgres-enum-array-grid-edit-results-2026-10-04/manifest.json)).
Grid input also keeps blank SQL NULL distinct from the empty array literal
`{}` ([evidence](../evidence/postgres-enum-array-grid-null-results-2026-10-04/manifest.json)).
Default CSV import also maps a blank whole-array field to SQL NULL while
retaining `{}` as the empty array ([evidence](../evidence/postgres-enum-array-default-null-results-2026-10-04/manifest.json)).

A `timestamptz[]` file-writer contract preserves distinct repeated-hour
instants, a BC instant, infinities and SQL NULL through JSON, CSV, XLSX and
replayed SQL, checked against native JSON and wire bytes ([evidence](../evidence/postgres-timestamptz-array-filewriter-results-2026-10-04/manifest.json)).
Under a New York session, a follow-up confirms PostgreSQL's native output uses
the two fall-back offsets while BookiE's decoded value remains canonical UTC;
binding and SQL replay in a later Kathmandu session preserve the original wire
bytes ([session evidence](../evidence/postgres-timestamptz-array-non-utc-session-results-2026-10-05/manifest.json)).
The workbook created in that session also survives LibreOffice Calc and
Gnumeric XLSX/ODS/XLSX re-saves with the same canonical UTC text and no formulas
([spreadsheet evidence](../evidence/postgres-timestamptz-array-non-utc-calc-results-2026-10-05/manifest.json)).

An `interval[]` file-writer case runs under `postgres_verbose` `IntervalStyle`
on one transaction backend and verifies text binding, all four writers and
replayed SQL against PostgreSQL JSON/wire oracles ([evidence](../evidence/postgres-interval-array-filewriter-results-2026-10-04/manifest.json)).

The SQLite STRICT `ANY` computed `CASE` and `COALESCE` paths now have app CSV
export/import coverage with native storage-class assertions; see the [CASE
consumer evidence](../evidence/sqlite-case-any-csv-roundtrip-results-2026-10-04/manifest.json)
and [COALESCE consumer evidence](../evidence/sqlite-coalesce-any-csv-roundtrip-results-2026-10-04/manifest.json).
The CASE workbook path now refuses empty TEXT without replacing the existing
destination ([XLSX refusal evidence](../evidence/sqlite-case-any-xlsx-refusal-results-2026-10-04/manifest.json)).
Computed COALESCE JSON output checks number/string distinctions, and XLSX output
checks numeric/shared-string cell kinds, including BLOB text encoding
([consumer evidence](../evidence/sqlite-coalesce-any-xlsx-results-2026-10-04/manifest.json)).

SQLite grouped `MAX()` over STRICT `ANY` now round-trips INTEGER, REAL, TEXT,
BLOB and NULL groups through typed CSV, checked by native `typeof()` and exact
BLOB-byte comparisons ([evidence](../evidence/sqlite-max-any-results-2026-10-04/manifest.json)).

SQLite grouped `MIN()` covers the same storage classes plus SQLite's native numeric-before-text ordering in a mixed group. Typed CSV re-import
preserves exact values, `typeof()` results, BLOB bytes and marker-shaped text
([evidence](../evidence/sqlite-min-any-results-2026-10-04/manifest.json)).

SQLite ordered `group_concat()` over STRICT `ANY` verifies native numeric-to-text
conversion, NULL skipping, empty-text separators, all-NULL output and marker-shaped
text. Typed CSV re-import preserves the exact aggregate text and SQL NULL
([evidence](../evidence/sqlite-group-concat-any-results-2026-10-04/manifest.json)).

SQLite grouped `SUM()` over STRICT `ANY` preserves SQLite's dynamic INTEGER,
REAL and NULL results through typed CSV re-import. Numeric text coercion,
nonnumeric text/BLOB coercion to REAL zero, and integer overflow refusal are
covered with native `typeof()` checks ([evidence](../evidence/sqlite-sum-any-results-2026-10-04/manifest.json)).

SQLite `total()` over STRICT `ANY` always returns REAL, including all-NULL and
empty input, and accepts an integer sum above `i64::MAX` without SUM's integer
overflow. Typed CSV re-import preserves every f64 result and native REAL class
([evidence](../evidence/sqlite-total-any-results-2026-10-04/manifest.json)).

SQLite grouped `AVG()` over STRICT `ANY` returns REAL for non-NULL groups,
including near-`i64::MAX` values, while all-NULL groups remain SQL NULL. Typed
CSV re-import preserves computed values and runtime classes ([evidence](../evidence/sqlite-avg-any-results-2026-10-04/manifest.json)).

SQLite `json_group_array()` over STRICT `ANY` preserves numeric and text
elements, formula-shaped text, Unicode, JSON null, and empty-group output (`[]`)
as exact JSON text through typed CSV re-import. The native `typeof()` oracle
checks the restored value remains TEXT; see
[`sqlite_json_group_array_any_csv_round_trip_preserves_json_null_and_text`](../../crates/app/tests/support/sqlite_any_contract/aggregate_csv.rs).

SQLite `json_group_object()` over STRICT `ANY` preserves ordered duplicate keys,
retains NULL values as JSON `null`, and returns `{}` for an empty group. It
checks version-specific NULL-label behavior: SQLite 3.50.0+ omits NULL keys,
while older system libraries' malformed native output is preserved exactly.
Exact output text and restored TEXT storage are checked through typed CSV; see
[`sqlite_json_group_object_any_csv_round_trip_preserves_native_text`](../../crates/app/tests/support/sqlite_any_contract/aggregate_csv.rs).

SQLite arithmetic expressions over STRICT `ANY` verify numeric coercion,
integer division, overflow promotion to REAL, divide-by-zero NULL and typed CSV
restoration ([evidence](../evidence/sqlite-arithmetic-any-results-2026-10-04/manifest.json)).

SQLite `json_extract()` over STRICT `ANY` preserves dynamic numeric/text/NULL
storage classes through JSON and XLSX export and typed CSV re-import. JSON keeps
large integers numeric and distinguishes JSON null from a missing path through
the companion kind column; XLSX uses numeric cells for numeric results and
shared strings for extracted text without formulas. Native `typeof()` and
`json_type()` remain the independent SQLite oracles ([evidence](../evidence/sqlite-json-extract-any-results-2026-10-04/manifest.json)).

SQLite `substr()` over STRICT `ANY` now round-trips INTEGER/REAL-derived text,
ordinary and empty TEXT, UTF-8 and binary BLOBs, and SQL NULL through typed CSV.
Native `typeof()` and `hex()` check source and restored values
([evidence](../evidence/sqlite-substr-any-csv-results-2026-10-05/manifest.json)).

