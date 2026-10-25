# Testing

Three layers, three tools. Each crate's test policy follows from its position in the dependency graph.

| Crate | Layer | Tools | Required for merge? |
|---|---|---|---|
| `core` | Pure traits + types | Unit tests in `crates/core/src/`, table-driven for type mappers | Yes |
| `storage` | Filesystem, the Secret Service through `oo7`, GSettings | Unit tests + integration tests with `tempfile` | Yes |
| `net` | TLS setup | Unit tests, a TLS handshake test against a local server | Yes |
| `ssh` | OpenSSH transport | Unit tests, `testcontainers-rs` tests against an OpenSSH server | Yes |
| `test-fixtures` | Containers for the other crates' tests | `testcontainers-rs` tests of the fixtures themselves | Yes |
| `session` | Sessions, connect, health | Unit tests over the fakes in `tablepro-test-support` and `tablepro_session::fakes`, plus `testcontainers-rs` tests | Yes |
| `drivers/<engine>` | Real engines | Unit tests, the conformance suites, `testcontainers-rs` integration tests | Yes |
| `app` | GTK 4 widgets | `#[gtk4::test]` widget tests; pure logic is unit-tested | Yes |

## Unit tests

In-crate, in `#[cfg(test)] mod tests` next to the code they cover. Standard Rust idiom.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_full_is_default() {
        let form = ConnectForm::new("postgres", tablepro_driver_postgres::PgDriver.capabilities());

        assert_eq!(form.tls.mode, TlsMode::VerifyFull);
    }
}
```

Run every test that needs no external service through meson, which sets the
environment each suite needs:

```bash
meson setup _build -Dprofile=development
dbus-run-session -- meson test -C _build --print-errorlogs
```

Five suites: `unit` is `cargo test --workspace --exclude tablepro`. `gtk`
is `cargo test -p tablepro` with `GSK_RENDERER=cairo`, `GTK_A11Y=test`,
`GDK_BACKEND=x11` and the build tree's schema directory, under a
`dbus-run-session` of its own when one is installed, so its bus names
and notifications never reach the desktop it runs on. It sets
`GNOTIFICATION_BACKEND=freedesktop`, since GLib picks the portal inside
Flatpak and the notification test answers with a freedesktop server on
that bus. `data` runs `desktop-file-validate` and `appstreamcli
validate`; the schema compiles with `--strict` as part of the build.
`packaging` runs the unit tests in `build-aux/tests` and checks that
`debian/copyright`, the RPM spec and the metainfo agree with `data/licenses`
and the version Meson builds. `po` runs `msgfmt --check` on each catalogue
in `po/LINGUAS`; gettext 0.26 and newer also check its `{name}`
placeholders. In a `-Dprofile=default` build, which the
packages run, the unit and gtk suites build with `--release` but without
its fat LTO, which would cost gigabytes and minutes per test binary.
Tests that need Docker or a Secret Service are ignored. Without a display
(SSH, containers), prefix with xvfb the way the CI fast job does:

```bash
xvfb-run -a dbus-run-session -- meson test -C _build --print-errorlogs
```

For a single crate, `meson devenv -C _build cargo test -p <crate>` runs
Cargo on the same build tree. It does not set the gtk suite's variables,
so for the app pass them:

```bash
GSK_RENDERER=cairo GTK_A11Y=test GDK_BACKEND=x11 meson devenv -C _build cargo test -p tablepro
```

## Integration tests

Each crate keeps its integration tests in `crates/<crate>/tests/`. A driver has one target, `crates/drivers/<engine>/tests/integration/main.rs`, with one module per topic.

For `storage`, integration tests build `StoragePaths::under(root, ..)` over a `tempfile::TempDir`, so every file lands under that root.

For network drivers, integration tests use [`testcontainers`](https://docs.rs/testcontainers/latest/testcontainers/) through the fixtures in `tablepro-test-fixtures`. Each network driver's `crates/drivers/<engine>/tests/integration/support.rs` turns a fixture into `ConnectOptions` and a connected `Connection`; SQLite's and DuckDB's open a file endpoint instead:

```rust
use tablepro_core::meta::{ObjectKind, ObjectScope};

use crate::support::{CALL, connect, setup, start, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_created_table_is_listed() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE TABLE plain (id int)"]).await;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");

    assert!(objects.iter().any(|object| object.name == "plain" && object.kind == ObjectKind::Table));
}
```

Keep the fixture alive for the whole test: dropping it stops the container.

### Container fixtures

`crates/test-fixtures` (`tablepro-test-fixtures`) holds the containers that need more than a default image: a generated PKI, TLS turned on in the engine's own config format, and OpenSSH servers with a chosen auth method. It is a dev-dependency only and depends on no other TablePro crate.

`TestPki::generate()` writes `ca.pem`, `unrelated-ca.pem`, `server.pem`, `server.key`, `client.pem` and `client.key` to a `TempDir`, private keys at 0600. The server certificate carries SANs `localhost` and `db.tablepro.test` and no IP SAN, so verifying against `127.0.0.1` is a name mismatch. The client certificate's CN is `tablepro_client`, which PostgreSQL `cert` auth matches against the role name.

Every TLS fixture has two principals:

- `password_credentials()`: user `tablepro`, which the server forces onto TLS (`ALTER USER ... REQUIRE SSL`, `hostssl ... scram-sha-256`, `require_secure_transport=ON`).
- `certificate_credentials()`: user `tablepro_client`, which authenticates with the client certificate (`REQUIRE X509`, pg_hba `cert`, ClickHouse `ssl_certificates`).

SQL Server has only the `sa` principal, because its TLS contract carries no client identity. Redis maps no certificate to a user, so `RedisFixture::start_tls` runs two servers in one container: the TLS-only one on 6379, where the ACL user `tablepro` logs in with its password, and one on 6380 with `tls-auth-clients yes`, which takes only a client with the CA's certificate, as its `default` user. `RedisFixture::start` is the plain server, with the same password on `default` and on `tablepro`. `MongoFixture::start` is a one-member replica set, `rs0`, with access control on and the root user `tablepro` in `admin`; its start script initiates the set and makes the user before the fixture is ready, so starting one runs no `docker exec`, whose result a `Send` future cannot await. `MongoFixture::start_tls` requires TLS on that member, with a client certificate optional, and runs a standalone server on 27018 with no login that takes only a client with the CA's certificate.

`CassandraFixture` runs Apache Cassandra or ScyllaDB (`CassandraFlavour`) with password authentication, a `tablepro` keyspace, a `tablepro_limited` role that may only read it, user-defined functions and materialized views. `CassandraTls` picks what its port takes: `Off`, `Required`, or `ClientCertificate`, which asks every client for a certificate, since neither server can ask one role and not another; the certificate role still logs in with its password. The fixture writes its settings into the image's own configuration file before the server starts, in the spelling the release reads, gives Cassandra 4.1 and later its TLS key as PEM and builds Cassandra 4.0 a PKCS12 keystore with the JRE's JavaScript engine. `CassandraFixture::cql` runs statements through the node's own cqlsh as the image's superuser.

`HbaMode` picks what the PostgreSQL fixture accepts: `Password` (the image defaults, no TLS), `HostSslOnly`, or `ClientCertificate`. Docker maps a published port anew each time a container starts, so a test that restarts the server starts it with `PostgresFixture::start_restartable`, which picks the host port itself; `stop` and `start_again` then bring it back where the session's connection points, with its data. `OpenSshFixture` takes an `SshAuthVariant`: `Password`, `PublicKey`, `UserCertificateAuthority` (only certificates that key signed log in), `KeyboardInteractive` or `HostCertificate`. `OpenSshFixture::start_with` also takes `OpenSshOptions`, which picks the release and sets sshd's `KexAlgorithms`, `MaxAuthTries` and `PubkeyAcceptedAlgorithms`. `SshKeyPair::generate_with` makes an Ed25519, RSA or ECDSA P-256 key, with a passphrase when given one, and `SshAgent` runs a private `ssh-agent` and loads a key with its passphrase. `HostKeyRevocation` builds a KRL from the running server's host key, and `ScriptedAskpass` writes a 0700 script for `SSH_ASKPASS`.

### Conformance

Every driver runs the same contract tests against its real server. `tablepro_test_support::connection_conformance_suite!` emits them from an engine adapter the driver's `crates/drivers/<engine>/tests/integration/conformance_engine.rs` implements (`ConformanceEngine`: how to start the server, connect, and spell a scratch table, a statement that never ends and a row source):

```rust
tablepro_test_support::connection_conformance_suite! {
    engine: PgEngine,
    docker: true,
    endpoint: network,
    server_stop: true,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: true,
    bounded_ddl: true,
}
```

The cases every engine runs: a created table is listed with its key, one operation's calls share one `CallOptions`, a query bound times out within its deadline, a cancelled editor run reports it and leaves the session ready, a read-only connection refuses writes (beside a writable one, unless the adapter's `READ_ONLY_BESIDE_WRITER` says the engine opens a database one way at a time, as DuckDB does), a write batch commits every step and a failed one ends as the driver's atomicity says, a row guard mismatch applies nothing, `close` is idempotent, a commit the engine keeps no record of resolves as `Unresolvable`, and `stream_read` streams every row in bounded batches.

Each flag adds cases and needs its engine trait:

| Flag | Adds | Needs |
|---|---|---|
| `endpoint: network` | a lost transport reports `ConnectionLost` | `NetworkConformanceEngine` |
| `server_stop: true` with `endpoint: network` | a dropped `query_bound` caller or editor run stops the server's statement, and the editor session then runs again or reports `Lost` | `ServerStopEngine`, which counts the statements carrying a marker the server still runs |
| `server_stop: false` with `endpoint: network` | a dropped caller ends at once and the connection serves the next call, and a dropped editor run frees the session: the protocol carries no stop (CQL) | `NetworkConformanceEngine` |
| `endpoint: file` | a dropped editor run stops, and the session takes the next run within the cancel grace | `ConformanceEngine` |
| `pool: pooled` | a probe succeeds while every pool slot is busy | `PooledConformanceEngine` |
| `pool: unbounded` | nothing: the engine has no slot limit (ClickHouse) | `ConformanceEngine` |
| `editor_transactions: true` | the row limit keeps the transaction and the statements after it | `EditorTransactionEngine` |
| `unsupported_types: true` | an unsupported type never decodes as NULL | `TypedConformanceEngine` |
| `bounded_ddl: true` | a schema-change batch is not cut off by the statement timeout | `BoundedDdlEngine` |

A flag that is off emits no test. `suite_flags_match_driver_capabilities` is always emitted and never ignored: it fails when `endpoint`, `server_stop` or `editor_transactions` disagrees with the driver's `DriverCapabilities` (`statement_stop` for `server_stop`), so those cases cannot be skipped by declaring less. `pool`, `unsupported_types` and `bounded_ddl` have no capability behind them: they describe the server, and MySQL and MariaDB differ on `bounded_ddl` under one driver, so the adapter states them and review checks them. `docker: true` marks every other case `#[ignore = "requires docker"]`; SQLite and DuckDB pass `docker: false` and `endpoint: file`, so their suites run in the unit suite.

Each case starts its own engine, then has two minutes (`CASE_LIMIT`) to finish, four for the large-table case (`LARGE_TABLE_CASE_LIMIT`). A driver that ignores a deadline or a cancel fails the case with its name instead of holding the test run.

### DDL conformance

`ddl_conformance_suite!` runs the structure tab's own plans against the server. The same `conformance_engine.rs` implements `ConformanceDdlEngine` on top of `ConformanceEngine` and invokes it: the engine's integer, text and timestamp types, its current-timestamp expression, and, for an engine whose `DdlDialect` creates no tables (ClickHouse), a CREATE TABLE of its own.

```rust
tablepro_test_support::ddl_conformance_suite! {
    engine: PgEngine,
    docker: true,
}
```

Every case but the last plans through `connection.dialect().ddl()` and runs the plan with `write_batch`:

- `ddl_plans_apply_and_read_back` creates a table with a quoted literal default and an expression default, then adds, renames and drops a column, changes its nullability and default, adds an index and a foreign key, renames the table, which has to stay listed in its own schema, and drops the tables. After each step `fetch_table_definition` has to match the draft. A step the dialect refuses has to be refused by its plan as well, with a reason, so no step is skipped without a check. Once the foreign key exists, the referenced primary key has to read as held by it.
- `failed_ddl_batch_outcome_matches_ddl_atomicity` sends two plans whose second statement the server rejects, and checks the outcome against `ddl_writes`: `RolledBack` and nothing applied, or `PartiallyApplied` and the first plan applied.
- `create_table_script_recreates_the_table` drops a table and runs its `create_table_script`, which has to bring back the same column definitions and index keys.
- `structure_changes_keep_rows_and_indexes` fills an indexed table, then changes a default and a nullability. The rows and the index have to come through, which on SQLite means through the table rebuild.
- `builtin_snippets_run_as_written` takes the SQL editor's built-in snippets for the connection's grammar, fills their table, index, column and value stops, with the row's `id` too on CQL, which finds a row only by its key, and keeps the rest as written (`tablepro_test_support::expand_snippet`), and runs each one through an editor session as the editor splits it: one statement each, all completing.

The PostgreSQL, MySQL, SQL Server, ClickHouse, SQLite and DuckDB targets run it, and the MySQL target runs it on MariaDB as well. SQLite and DuckDB pass `docker: false`, so their cases run in the unit suite.

### Large-table conformance

`large_table_conformance_suite!` runs `a_million_row_table_pages_to_its_end_and_exports` through `LargeTableEngine`, whose statements fill the scratch table with 1,000,000 rows, about 100 MB:

- It counts the table, then pages from the first page to the end by the browse tab's default page size, each page read past the edge row's key, by offset where the engine pages that way, or resumed from the server's paging state, as `BrowsePager` moves on. The last page is then read from the end, or by offset where the server pages. Every row is checked, in id order or, where the server pages a scan in its own order, once each.
- It exports the table through the statement `build_export` writes, streamed by `stream_read` with no deadline into a CSV file in 64 KiB chunks, as the export dialog's Entire Table does. Every line of the file is checked.
- The walk, each page and the export have time bounds, and where pages seek, the last pages may not take much longer than the first. Where the server pages, the last page is reached only by reading every row before it, so it may take up to twice as long as the export, which reads them all at the same speed. Neither the walk nor the export may raise the process's resident peak (`VmHWM`, reset through `/proc/self/clear_refs`) past a memory bound. The bounds are constants in `crates/test-support/src/conformance/cases/large_table.rs`.

The peak is the whole process's, so the case needs a process to itself. The PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra and ScyllaDB targets pass `docker: true` and run under cargo-nextest, which gives each test a process of its own. The `ci` nextest profile prints its times and memory for a passing run, so the job log keeps what the bounds are set from.

SQLite and DuckDB pass `docker: false`, so the case runs in the unit suite, where `cargo test` runs the tests of one binary in one process. It is a test target of its own, as `crates/drivers/sqlite/tests/large_table.rs`, which holds nothing else and includes the adapter from `tests/integration/sqlite_engine.rs`. A passing run there prints nothing; `cargo test -p tablepro-driver-sqlite --test large_table -- --nocapture` shows the numbers.

### Large-catalog case

`crates/app/src/ui/workspace/tests/large_catalog.rs` fills PostgreSQL with 100 schemas of 500 tables, the default schema among them, and MySQL with one database of 50,000. It puts the sidebar and a SQL editor on screen over a session the app's own connector opens:

- The sidebar lists every schema's tables, read and indexed the way the workspace does, then its search takes `i`, `in` and an empty search.
- The editor's completion opens after `FROM `, narrows as `i` is typed, and opens again after a schema's dot.
- Each step has a time bound, from the action to its result on screen, and none may stall the main loop past 100 ms, which `StallProbe` (`crates/app/src/test_support/stall_probe.rs`) measures as the longest gap between runs of a high-priority timeout. The catalog may not raise the resident peak (`ResidentPeak`) past a memory bound. The bounds are constants at the top of the file.

The report gives each step's time, its stall and the CPU time the GTK thread spent on it: on a loaded machine the stall stretches and the CPU time does not, which tells a slow step from a busy machine. MySQL creates a table in milliseconds, so its fill takes minutes, and the `ci` profile gives these cases 15 minutes rather than five.

The cases are `#[gtk4::test]`s in the app's library, so they need a display. CI runs them in the `integration-app` job under `xvfb-run` with the gtk suite's environment, and the `ci` nextest profile prints their numbers for a passing run. Locally:

```bash
GSK_RENDERER=cairo GTK_A11Y=test GDK_BACKEND=x11 xvfb-run -a dbus-run-session -- \
  meson devenv -C _build cargo nextest run -p tablepro --lib --run-ignored only large_catalog
```

### Value corpus

`value_corpus_suite!` checks that real values read back as the grid shows them. Each driver's `crates/drivers/<engine>/tests/integration/value_corpus.rs` implements `ValueCorpusEngine` and invokes it:

```rust
tablepro_test_support::value_corpus_suite! {
    engine: PgEngine,
    docker: true,
}
```

The corpus is a list of `CorpusColumn`s: a column clause, values of it written as SQL, and the text each one shows, or NULL. It covers the engine's dates and times at their extremes and in other zones, high-precision and negative decimals at their scale, JSON, UUIDs, Unicode text, binary values and the engine's other common types. `value_corpus_reads_as_the_grid_shows` adds each column to a scratch table, inserts its values, and reads them back three times: through `read_page`, as a table tab reads a page, through `build_export` and `stream_read` behind a `DeclaredPrecisionSink`, as Export All reads one, and through an editor run of a plain SELECT. The export has to show what the page shows. Each value's text is `value_text` on the type of the column it came back in, the text the grid draws, `<unreadable type>` for a value the driver could not read, and every value that differs is listed in one failure, with a column the server refused. Where the two paths differ on purpose, the value says what each shows (`CorpusColumn::shows_apart`): a MySQL TIMESTAMP is an instant in a table tab and the server's wall time in the editor, and a PostgreSQL run shows the server's own text, as psql does. A value that shows the wrong text is a decoder bug: fix the decoder, never the corpus.

Every target runs it, the MySQL target on MariaDB as well, and SQLite's and DuckDB's run in the unit suite.

### Export round trip

`round_trip_suite!` checks that a file the export writes, and rows the grid copies, load back with the same rows. Each driver's `crates/drivers/<engine>/tests/integration/round_trip.rs` invokes it with an engine that implements `ValueCorpusEngine` and `LargeTableEngine`:

```rust
tablepro_test_support::round_trip_suite! {
    engine: PgEngine,
    docker: true,
    near_limit: true,
}
```

- `csv_export_imports_back_as_the_same_rows` loads each corpus column into a table, exports it as CSV and imports the file into an empty copy, through `import_csv`, which runs the plan the import dialog runs. It does this under four pairings of export and import options that are meant to lose nothing: every delimiter, quoting always or where needed, LF, CRLF and CR line breaks, NULL written and read as `NULL`, and formulas left as they are. Row count and the text of every row have to match. A column of a kind `read_only_reason` names (bytes, arrays, spatial, variant and composite values) and a value `edit_text` gives no text for, such as a blob in a SQLite column typed by its values, have no CSV text the import reads back, so the SQL case covers them.
- `sql_insert_export_runs_back_as_the_same_rows` exports each corpus column as SQL INSERT into an empty copy and runs the file as the editor runs one: split by the engine's grammar and sent a batch at a time. Every value has to come back with the same text and of the same kind.
- `tsv_copy_pastes_back_as_the_same_rows` writes each corpus column's rows as the grid's Copy does, as tab-separated text and as the cells it offers beside the text (`CellsEncoder`), reads each as a paste does (`PastedTable`) and saves the rows into an empty copy as a table tab saves new ones (`plan_save`). Rows are compared in `id` order without the `id`, since a paste leaves an id the server numbers, such as SQLite's row id, to the server: by text for the text, and by text and kind for the cells, which keep how each value was stored. The columns and values the CSV case skips are skipped here too.
- `csv_export_near_the_import_limit_imports_back`, with `near_limit: true`, fills a table through `LargeTableEngine` so its CSV under the export defaults lands within 1 MiB under `MAX_CSV_FILE_BYTES`, imports it into an empty copy, and compares a hash of every row. ClickHouse passes `false`: its import sends values in the request URL, 8 KiB a statement, so such a file takes some 8,000 statements and longer than a case may run.

Each case has four minutes (`ROUND_TRIP_CASE_LIMIT`). Every target runs the suite, the MySQL target on MariaDB as well, and SQLite's and DuckDB's run in the unit suite.

### Keyspace conformance

A key-value engine runs `keyspace_conformance_suite!` in place of the SQL suites, through `KeyspaceEngine`: how to start the server and connect, a route the case can drop (`FaultTransport`), the engine's commands that fill a key of each type, wait on a key, write a key and read a whole key, and how many commands the server holds waiting on a key. Redis's adapter is `crates/drivers/redis/tests/integration/conformance_engine.rs`:

```rust
tablepro_test_support::keyspace_conformance_suite! {
    engine: RedisEngine,
}
```

The cases: keys are listed with their types; a pattern is matched on the server; a listing stops at its limit and says so; every type reads in windows to its end with every entry; a missing key reads as none; a stopped command ends as cancelled within the cancel grace, the server lets it go, and the session runs again; a dropped run stops the command on the server; a statement timeout ends a waiting command as one the server stopped; a read-only connection refuses a write in the editor and in `stream_read` before it reaches the server; `stream_read` streams every row; a probe answers while a command waits; `close` is idempotent; and a dropped route reports `ConnectionLost` within the deadline plus the cancel grace. `keyspace_suite_matches_driver_capabilities` is never ignored and fails when the driver's `data_model` is not `KeyValue`. The engine also runs the TLS suite.

### Document conformance

A document engine runs `document_conformance_suite!` in place of the SQL suites, through `DocumentEngine`: how to start the server and connect, a route the case can drop, the engine's statements that fill a collection, never end, and read while writing, and how many operations the server is running under a marker. MongoDB's adapter is `crates/drivers/mongodb/tests/integration/conformance_engine.rs`:

```rust
tablepro_test_support::document_conformance_suite! {
    engine: MongoEngine,
}
```

The cases: collections are listed in their database; fields become columns with the key first; pages read every document in order; a filter and a sort are read on the server; a field edit saves and reads back; a save on a document that is gone changes nothing; an insert and a delete land; a read-only connection refuses a save, an editor write, a read that writes and an export that writes before sending; a stopped statement ends and the session runs again; a dropped run stops the statement; a timed-out statement is stopped by the server; an editor result keeps the row limit; `stream_read` streams every document; a probe answers while a statement runs; `close` is idempotent; and a dropped route reports `ConnectionLost`. `document_suite_matches_driver_capabilities` is never ignored and fails when the driver's `data_model` is not `Document`. The engine also runs the TLS suite.

### TLS conformance

Every network driver's `crates/drivers/<engine>/tests/integration/tls.rs` also runs `tls_conformance_suite!` against a TLS-only server built from `TestPki`:

```rust
tablepro_test_support::tls_conformance_suite! {
    engine: PgTlsEngine,
    client_identity: true,
}
```

The adapter (`TlsConformanceEngine`) gives the issuing and the unrelated CA file, the name on the server certificate and the error category a plaintext connect gets. The cases: Verify full with the issuing CA connects; with an unrelated CA it reports `UnknownIssuer`; with the wrong server name it reports `NameMismatch`; Require connects without a CA, and a CA file with Require is refused as a `ConfigError::CaFileUnsupported` before anything is sent; Disable against the TLS-only server is refused. `client_identity: true` adds a case where the server requires the client certificate, through `ClientIdentityEngine`; SQL Server passes `false`. An engine whose server asks every client for a certificate or none names a second engine for that case with `identity_engine:`, as the Cassandra driver does, so the other cases run against a server that asks for none. MongoDB runs the suite twice, on a direct route, where the client library does TLS, and on a forward, where the driver's relay does. Every case needs Docker, and `tls_suite_flags_match_driver_capabilities` checks the flag against the driver's TLS capabilities without it.

### Ignore reasons

Two reasons are allowed:

- `#[ignore = "requires docker"]` for testcontainers suites.
- `#[ignore = "requires a Secret Service"]` for tests that talk to a keyring.

The workspace denies `clippy::ignore_without_reason`, so a bare `#[ignore]` fails the build.

### Running the docker tests

CI runs one job per package with docker tests:

```bash
cargo nextest run --locked --profile ci -p tablepro-driver-mssql --run-ignored only
```

`.config/nextest.toml` puts each package that has Docker tests in a test group with one thread, and for the app only its integration targets and the large-catalog case, so the tests of one suite never compete for a container. Its default filter leaves out three SQL Server tests that need tiberius#459 ([sql-server.md](drivers/sql-server.md#stops-and-timeouts)). The `ci` profile writes a JUnit report to `target/nextest/ci/junit.xml` and kills a test that runs past five minutes, so a hang fails with the test's name.

A new package with Docker tests gets a test group and an override in `.config/nextest.toml`, and an entry in the `integration` matrix of `.github/workflows/build-linux.yml`.

Locally, with [cargo-nextest](https://nexte.st/) installed:

```bash
cargo nextest run -p tablepro-driver-postgres --run-ignored only
```

meson and distro builds use cargo test, which works too:

```bash
cargo test -p tablepro-driver-postgres -- --ignored --test-threads=1
```

### Server releases

A fixture starts its engine's default release unless the engine's variable names another:

| Variable | Releases | Default |
|---|---|---|
| `TABLEPRO_TEST_POSTGRES` | 13, 14, 17, 18 | 17 |
| `TABLEPRO_TEST_MYSQL` | 8.0, 8.4, 9.7 | 8.4 |
| `TABLEPRO_TEST_MARIADB` | 10.11, 11.4, 12.3 | 11.4 |
| `TABLEPRO_TEST_MSSQL` | 2017, 2019, 2022, 2025 | 2022 |
| `TABLEPRO_TEST_CLICKHOUSE` | 26.3, 26.8 | 26.8 |
| `TABLEPRO_TEST_CASSANDRA` | 4.0, 5.0 | 5.0 |
| `TABLEPRO_TEST_SCYLLA` | 2025.1, 2026.1 | 2026.1 |
| `TABLEPRO_TEST_REDIS` | 7.4, 8.10 | 8.10 |
| `TABLEPRO_TEST_MONGO` | 7.0, 8.0 | 8.0 |
| `TABLEPRO_TEST_OPENSSH` | 9.9, 10.3 | 10.3 |

`crates/test-fixtures/src/fixture_image.rs` pins each release's image, and each engine's version type (`PostgresVersion`, `MysqlVersion`, `MariadbVersion`, `MssqlVersion`, `ClickHouseVersion`, `CassandraVersion`, `ScyllaVersion`, `RedisVersion`, `MongoVersion`, `OpenSshVersion`) reads its variable through `ServerVersion::selected`. An empty value picks the default; a release the fixtures do not pin fails the fixture with the ones they do. PostgreSQL 13 is past end of life and stays only for the catalogue test of the driver's query for servers before 14.

The `integration` job runs each driver's suite on the defaults, then once more for each entry with a `release`: PostgreSQL 14 and 18, MySQL 8.0 with MariaDB 10.11, MySQL 9.7 with MariaDB 12.3, SQL Server 2017, 2019 and 2025, ClickHouse 26.3, Cassandra 4.0 with ScyllaDB 2025.1, Redis 7.4, MongoDB 7.0, and OpenSSH 9.9 for `tablepro-ssh`. The README's [supported servers](../README.md#supported-servers) table says why those releases and not others. A test that checks the server's version reads it from the fixture (`PostgresFixture::version`, `MysqlFixture::server_version`, `MssqlFixture::version`, `ClickHouseFixture::version`, `CassandraFixture::server_version`, `RedisFixture::version`, `MongoFixture::version`, `OpenSshFixture::version`), never from a literal, so it holds on every release.

Locally, set the variables for the run:

```bash
TABLEPRO_TEST_MYSQL=8.0 TABLEPRO_TEST_MARIADB=10.11 cargo nextest run -p tablepro-driver-mysql --run-ignored only
```

A new release gets its image in `fixture_image.rs`, a variant in its version type, a matrix entry in `.github/workflows/build-linux.yml` and a row in the README table. A release past its vendor's end of life loses all four.

### Docker or Podman

Upstream CI uses Docker. Fedora ships Podman instead, and on Debian it is the easier install; either way, point testcontainers at Podman's rootless socket:

```bash
sudo dnf install -y podman   # or: sudo apt install -y podman
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
cargo nextest run -p tablepro-driver-postgres --run-ignored only
```

Do not bother with `TESTCONTAINERS_RYUK_DISABLED`. That is a testcontainers-java / go setting; the Rust crate has no Ryuk reaper and stops each container when its handle drops.

Every fixture starts its container through `tablepro_test_fixtures::start_container`, which takes a closure that builds the request and, when pulling the image failed, builds and starts it again, up to three times 5 seconds apart. testcontainers pulls once, and Docker Hub sometimes ends a pull early ("bytes remaining on stream"), which failed every test that needed the image. A test that starts a container of its own goes through it too.

`curl --unix-socket "${DOCKER_HOST#unix://}" http://localhost/_ping` should print `OK` before you run the suite. `--unix-socket` takes a filesystem path, so the `unix://` prefix has to come off.

A test that panics hard can still leave a container behind. `podman container prune` clears them.

Tests run inside a container reach the fixtures through the bridge gateway, such as `172.17.0.1`, which the test certificate does not name. A Verify full case on a direct route where the driver takes no server name override there (MySQL, MongoDB, and the system trust tests) then fails with `NameMismatch`. CI runs the suites on the runner itself, where the fixtures answer on `localhost`.

### Regression names

A test that guards a critical audit finding starts with the finding id, `f001_` to `f006_`. [regression-tests.md](regression-tests.md) has the commands that run them and lists every guard with its file, and `build-aux/tests/test_regression_names.py`, in the `packaging` suite, fails when the list and the code disagree.

## App / UI tests

GTK code is tested with `#[gtk4::test]`, which runs each test on a single GTK thread after `gtk::init`. Pure logic still belongs in `app::services` with plain unit tests.

Helpers live in `crates/app/src/test_support`, compiled only for tests:

- `drain_main_context()` runs pending main-loop sources. `wait_until(timeout, condition)` iterates the main loop until the condition holds or the timeout passes, so a missing signal fails the test instead of hanging it. `finish_on_main(timeout, future)` runs a future on the main context and gives it up at the timeout.
- `SignalLog::connect(object, signal, extract)` records emissions and disconnects when dropped.
- `OwnedWindow` holds a window a test presents, and on drop clears its focus, destroys it and drains the main context. GTK keeps every window, and whatever its widgets hold, until it is destroyed, and GTK 4.22 leaks a focused widget that is hidden and then unparented. The `cargo test` run of the gtk suite is one process, which package builds start with a limit of 1024 open files, so a leaked window's runtime and SQLite pool add up across tests.
- `end_application(app)` ends an application a test registered the way `g_application_run` ends one: `shutdown`, then leaving the session bus. GtkApplication holds itself from startup until shutdown, so a registered application a test only drops leaks with every service it owns. `TestWindow` and the application tests' `TestApp` call it when dropped.
- `descendants`, `find_by_action_name` and `first_descendant_of_type` walk a widget tree.
- `MemorySettings` compiles the schema into a `TempDir` behind the memory backend, so a test never touches the developer's dconf database.
- `FakeSession` is a session over a fake connection; `FakeClocks` and `FakeProbe` stand in for the suspend clocks and the reachability check.
- `KeyInjector` presses real keys through XTEST, so a test meets every capture, class and bubble handler in the order GTK runs them. It needs an X11 display, which is why the gtk suite sets `GDK_BACKEND=x11`; `focus_only` first closes any window an earlier test left open. Such a test goes in a `real_keys` module, which nextest runs with no other test beside it, since a window another test presents takes the keyboard focus.
- `FocusThief` takes the focus from a test's window with a window of its own, as another application does, then hands it back without running the main loop, so the focus-in reaches the window before its next frame. It needs the same X11 display.
- `shortcut_keys` reads the keys a controller or a widget class binds, for the accelerator table's collision tests.
- `assert_labelled(widget)` checks that a screen reader can name a control:
  - an `adw::PreferencesRow` needs a non-empty title;
  - an `adw::EntryRow` or `adw::PasswordEntryRow` must keep its inner text field labelled by that title;
  - an `adw::ActionRow` with an activatable widget must keep that widget labelled;
  - any other widget, such as an icon-only button or a bare entry, needs an accessible label or a labelled-by relation.
- `unlabelled_icon_buttons(root)` lists the icon-only buttons under `root` that a screen reader reaches and cannot name, and `tooltips_with_keys(root)` the tooltips that spell out a key, which belongs on the accessible node. `ui::a11y::tests` walks every template in the GResource: an icon-only button the template does not label needs an id, and a label once its class is built, which is where `describe_icon_button` gives it one.

The gtk suite sets `GTK_A11Y=test`, so results never depend on an AT-SPI bus. With `GTK_A11Y=none`, GTK records no accessible properties and `assert_labelled` returns `TestBackendMissing` instead of a wrong verdict.

The suite's `app-scale-2` test runs the grid, ER diagram, editor view and window geometry tests again with `GDK_SCALE=2`, the scale a 200% display gives GDK, so a size worked out in device pixels rather than logical ones fails on CI and not only on a HiDPI screen. Fractional scales are left to the [display scale pass](#display-scales), since Xvfb has none.

Two harnesses build the app's real objects over fakes:

- `TestWindow` (`crates/app/src/ui/session_window/tests/mod.rs`) starts a `TableProApplication` with one window on the picker, a saved connection in its list and a `FakeConnector`. `TestWindow::connected` opens that connection and waits for its workspace. Each test registers an application id of its own, so it never meets another test, or a TablePro the developer has open, on the session bus. `test.hold` is the application's `CountingHold`.
- `workspace::test_workspace::Workspace` builds a `WorkspaceHandle` with one tab over a scripted connection, for the save and close prompt tests.

Both turn GTK animations off, so a dialog or a page change finishes before the next line runs.

### Background work and time

A `#[gtk4::test]` has no tokio runtime. `test_runtime()` builds an `AppRuntime` the test owns, and its `tasks()` go to the code under test. A `#[tokio::test]` gets the `Tasks` of its own runtime from `paused_tasks()`, and with `start_paused = true` tokio's clock stands still and jumps to the next timer whenever every task is waiting, so a test of a deadline, a backoff or a debounce runs in no time and never flakes on a slow runner. The session crate's tests use the same pattern for the health monitor, the catalog and the operation runner.

### Holds

`CountingHold` (`tablepro_session::runtime`) is the test `ProcessHold`: it counts live tokens. A test that work holds the process checks that `live()` is 1 while the work runs and 0 once it ends, and that the work's effect is in place before the count drops.

### Dialogs

- `workspace::answer(window, response)` clicks the button of the alert `window` shows, so the alert closes itself and emits its response in the order a user's click does. `workspace::visible_alert(window)` returns that alert.
- `test_support::respond(dialog, response)` clicks the button of a presented alert the test holds. Never emit `response` by name: that skips the close a click makes first, so a `closed` handler sees the signals in an order no user can produce.

A test that a step logs no GLib critical turns criticals fatal around that step and restores the old mask after:

```rust
let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
let answered = crate::workspace::answer(&test.window, "reset");
crate::test_support::drain_main_context();
glib::log_set_always_fatal(previous);
```

A critical then aborts the process with the message, for example libadwaita's "Trying to close AdwAlertDialog ... that's not presented". cargo-nextest runs each test in a process of its own, so it reports that one test as failed. `cargo test`, which the Meson `gtk` suite runs, has every test of the `tablepro` library in one process: the abort ends the whole binary and the tests after it never run.

### Fakes

`tablepro-test-support` holds the driver contract's fakes, which every crate's tests share: `FakeDriver`, `FakeConnection` scripted through `ConnectionScript`, `FakeEditorSession` with `FakeRun`, `FakeSecretVault`, `FakePrompter` and `FaultTransport`. A `FakeReply` answers at once, after a delay unless the deadline or cancel comes first, late whatever the caller asked, once the test releases it, only once stopped, or never. `CallCounters` counts the calls a connection received after it was handed over. `tablepro_session::fakes` adds `FakeConnector` and `FakeCredentialSource` behind the session crate's `fakes` feature, which only the app's dev-dependencies turn on.

### Application tests

The tests in `crates/app/tests` that start TablePro run without the test harness (`harness = false` in `crates/app/Cargo.toml`): GTK allows one application per process, on its main thread. Each binary has its own `main` and runs TablePro in child processes. The ones that talk to it over D-Bus give it a private session bus through `gio::TestDBus`, so a TablePro the developer has open never answers.

| Test | What it checks |
|---|---|
| `application_uniqueness` | a second plain launch activates the running instance and exits without opening a window, and `--new-window` opens one there |
| `application_lifecycle` | Quit waits for a session's close within the close timeout and gives up on a close that hangs, a cancelled close keeps the app running, and an editor session's close holds the process |
| `application_session_restore` | the windows open at quit open again at the next launch, and a window closed first does not |
| `kill_during_save` | TablePro killed with SIGKILL halfway through a grid save to a SQLite file leaves none of that save in the file and no lock on it. The next launch restores the session, and its history, settings and saved tabs read back with nothing moved aside |
| `open_files` | a file handed over D-Bus opens a window on it, the same file brings that window forward, and another file opens a second window |
| `accessibility` | every control a screen reader reaches has a name, on the picker, connecting, connect failed and workspace pages and in the connect and preferences dialogs |
| `startup`, `i18n_catalog`, `logging` | the command-line options, a missing schema, the translation catalogue and the log setup |

They need a display and a session bus, so run them the way CI does:

```bash
xvfb-run -a dbus-run-session -- meson test -C _build --suite gtk --print-errorlogs
```

or one at a time, `xvfb-run -a dbus-run-session -- meson devenv -C _build cargo test -p tablepro --test application_lifecycle`. `startup` needs the build Meson configures, so it fails under plain Cargo. cargo-nextest asks each test binary to list its tests, which a harness-free binary does not do, so run these with `cargo test`.

`accessibility` runs in the test binary's own process instead. Each of its six scenarios starts a TablePro there under an application id of its own, one after another, on the main context. It needs `GTK_A11Y=test`; pass scenario names after `--` to run only those. It leaves to libadwaita the parts libadwaita builds and names with a tooltip alone: a tab's close button, a password row's peek button and the preferences dialog's search button.

Policy:

- Pure logic: extract to `app::services::<thing>` and write plain unit tests.
- Widgets the app builds: a `#[gtk4::test]` that constructs the widget, drives it through its actions or signals, checks the result, and runs `assert_labelled` on the controls a user reaches.
- A flow across windows or launches: an application test.
- UI changes still carry before and after screenshots in the PR description.

## Scripts, the editor and structure review

### The script planner

`crates/core/tests/script_corpus.rs` holds the planner's fixtures, by grammar:

- A named case for each rule an engine's client follows: dollar quotes and `BEGIN ATOMIC` bodies, a procedure with `DELIMITER` and one without, trigger bodies, `GO` with a count, heredocs, `#` and `//` comments, backslash escapes with the setting on and off, mongosh statements that end at a line break unless the next line goes on with `.`, and text left open, which keeps the statements before it.
- `lexer_matches_sqlparser_where_engines_agree` checks the semicolons the lexer finds in `AGREED_CASES` against sqlparser's tokenizer, on cases where sqlparser reads the text as the engine does.
- A proptest runs every grammar over random text with multibyte characters: the tokens cover the text with no gap, every range ends on a character boundary, and batches never overlap.

`crates/drivers/sqlite/tests/script_plan_matches_sqlite3_complete.rs` checks every prefix of a SQLite corpus against SQLite's own `sqlite3_complete`. A new rule gets a named case, and a place in `AGREED_CASES` when sqlparser reads it the engine's way.

The real servers run scripts in tests ignored with `requires docker`: MySQL and MariaDB create a trigger and procedures with and without `DELIMITER` (`create_trigger_and_procedure_in_session`), SQL Server runs `GO` batches past a failed one (`go_batches_run_in_order_and_continue_after_an_error`), and PostgreSQL splits with backslash escapes once `standard_conforming_strings` is off (`standard_conforming_strings_off_splits_with_backslash_escapes`).

### The editor

Editor tests run on a `FakeEditorSession` scripted with `Replies<FakeRun>`, never a server:

- `FakeRun::completed` streams the events it is given, `failed` ends in a statement the server refused, `session_error` fails the session itself (`EditorSessionBusy`, a lost connection), and `until_stopped` ends only at a cancel or the deadline. `taking` adds a delay, and `leaving` sets the `TransactionState` the run leaves.
- `Replies::when_sql_contains` ties an answer to a statement, so a test can fail the third of five.
- `texts` returns what each run was sent, so a test asserts the split itself, such as `GO 2` sending its batch twice. `stopped_runs` counts the runs a cancel or a timeout ended, and `close_count` the closes.
- The fake keeps the session's rules: a run while another runs gets `EditorSessionBusy`, and a lost session stays lost.

The tests in `crates/app/src/ui/editor/script_runner.rs` drive `run_batches` under tokio and fold its events into a `RunLog`. The widget tests in `crates/app/src/ui/editor/tests.rs` build a `SqlEditor` over a `Session` whose `ConnectionScript` hands out the fake from `open_editor_session`, run it, wait until `is_running` is false, then check the results list, the transaction label, the history and what was sent.

### Structure review

`crates/app/src/workspace/tests/structure_review.rs` saves a structure tab through `WorkspaceHandle::save` on the `workspace::test_workspace::Workspace` harness and answers the review with `workspace::answer`. A dropped column shows the review with its SQL, Cancel sends nothing, Apply runs one write batch, an additive save on an engine that applies DDL in one transaction starts without a review, a draft changed during the review is not saved, and a second save during the review opens no second one. The close guard's own tests check that its Save reviews too, and that a declined review keeps the window open with no alert and starts none of the saves after it.

## Manual passes

What a person checks on a desktop because no suite can, each with the date it last ran, where, and what it found. A problem a pass finds is fixed or filed, and the pass runs again when what it covers changes.

### Display scales

The app at 100, 125, 150, 175 and 200% on GNOME Wayland, at 200% on X11, on two monitors at different scales with the window moved from one to the other while a table, an editor and an ER diagram tab are open, on KDE Plasma Wayland at 125 and 150% with the Adwaita style, and at 150% with Large Text. At each scale: grid text, row height, header, pager and saved column widths; the focused cell ring, the selection, the row number column with its pending icons, and the marks on changed and deleted values; the SQL editor's text, gutter and completion list; the sidebar, the connect dialog, Preferences, the save alert, the main menu and About; the app icon and the three symbolic icons in `data/resources/icons`.

#### 2026-10-24

Ran in the `tablepro-linux-dev:26.04` container on an Apple silicon Mac, without a GPU: Mesa's llvmpipe drew everything in software. GTK 4.22.4, libadwaita 1.9.1, GtkSourceView 5.18.0, Adwaita Sans 11 and DejaVu Sans Mono 11, since Ubuntu ships no Adwaita Mono.

| Configuration | How | Result |
|---|---|---|
| GNOME Wayland 100, 125, 150, 175, 200% | GNOME Shell 50.1 `--headless` with one virtual monitor, 2560×1600 (2880×1800 at 150%, 2800×1750 at 175%, where Mutter offers those scales), the scale set through Mutter's `DisplayConfig` | Drawn at the monitor's scale, never stretched. Grid text, rows, header, pager, tints and the 2 px focus ring hold at every scale; the saved widths of `status` (72) and `note` (96) show the same text at each. Dialogs, alerts and menus lay out as at 100%. The problems below |
| X11 200% | Xvfb, with xsettingsd handing GTK `Gdk/WindowScalingFactor 2` as GNOME's settings daemon does on X11; GNOME 50 has no X11 session | As Wayland at 200% |
| Two monitors | 1920×1080 at 100% and 2560×1600 at 200%; the window, with a table, an editor and an ER diagram tab, moved to the second and back | Each move redraws at the new monitor's scale; layout, column widths and the diagram's cards are the same on both |
| KDE Plasma Wayland 125, 150% | KWin 6.6.6 `kwin_wayland --scale`, nested in Xvfb since its virtual backend takes no screenshots, without the Plasma shell; GTK draws its own header bar and the Adwaita style | As GNOME at the same scale: the grid, tints and focus ring, the editor and its completion list, the dialogs, the main menu and the ER diagram lay out the same |
| 150% with Large Text | GNOME at 150% with `text-scaling-factor` 1.25, read through the settings portal | Text a quarter larger and rows taller with it, nothing clipped; the connect dialog's title shortens to "Connect to PostgreS…" beside Test and Connect, as a header bar does |

Problems it found, each fixed with it:

- The app never called `gtk_source_init`, so GtkSourceView's stylesheet was missing: the completion list had no background and no gap between a name and its type, and with its rows hidden it asked for no width. GDK refuses such a popup, so once a word had no match the list never came back, at any scale and on X11 too. The application's startup now calls `sourceview5::init`.
- `table-relation-symbolic` (Show ER Diagram) drew its rows on half pixels and `statement-pending-symbolic` (Not Run) had a 1.5 px ring and round dots, so both were soft at 100%; both are redrawn on the 16 px grid.
- A new editor tab opened from the header button, the sidebar or Ctrl+T with the focus outside the tabs left the keyboard focus where it was, so typed SQL went to the sidebar.

Left for a machine with a GPU and a HiDPI screen: the GL and Vulkan renderers on a real driver, text on a physical panel, a touchpad's scrolling and zoom, and an X11 desktop that composites.

## CI

`.github/workflows/build-linux.yml` builds and tests the app, `.github/workflows/linux-packages.yml` builds, installs and starts the .deb and .rpm, and `.github/workflows/release-linux.yml` publishes a `linux-v*` tag. Each workflow's `on:` and each job's `if:` say when it runs; its steps say what it runs. To run the same checks locally: the [fast-job commands](../CONTRIBUTING.md#fast-job-commands) and `build-aux/packaging/build-packages.sh`.

`.github/workflows/ci.yml` calls `build-linux.yml` for a pull request, a push to `main` and a manual run, never for a `release/**` push. A change to Markdown alone, other than `CHANGELOG.md` and `docs/regression-tests.md`, runs only its Documentation links job. The required check is `CI` (`.claude/rules/ci.md`).

## Coverage

No job collects coverage, and there is no coverage threshold.

## Mocking

Avoid mock objects. We do not mock drivers, the filesystem, or `tokio::time`. Either use a real implementation (testcontainers, `tempfile`, `tokio::time::pause`) or extract the logic to a pure function and test that. The fakes in `tablepro-test-support` are not mocks: they implement the driver contract and keep its rules, so the code under test meets what a conforming driver does, and each real driver runs the conformance suites against its own server.

If a test cannot be written without a mock, the design is wrong. Refactor before writing the mock.
