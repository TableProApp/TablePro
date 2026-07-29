# Adding a database driver

This is the canonical contributor task. Every database engine TablePro Linux supports has a driver crate under `crates/drivers/`. There is no plugin system: a driver is a Rust crate, statically linked, registered in one place at startup. See [decisions/0001-no-plugin-system.md](decisions/0001-no-plugin-system.md) for why.

End to end, adding a driver is six steps:

1. Pick the underlying Rust library
2. Create a new crate
3. Implement `core::DatabaseDriver` and `core::Connection`
4. Add the crate to the workspace
5. Register the driver in `app::main`
6. Add tests

Each step is small. The whole task takes between half a day (PG-shaped engines) and a week (Oracle-shaped engines that need C FFI).

## 1. Pick the Rust library

| Engine | Recommended crate | Notes |
|---|---|---|
| PostgreSQL | `sqlx` with `runtime-tokio` + `tls-rustls` + `postgres` | Fully async, prepared statements, streaming. |
| MySQL / MariaDB | `sqlx` with `mysql` feature | Same shape as PostgreSQL. |
| SQLite | `sqlx` with `sqlite` feature | File-based, no network. |
| MSSQL | `tiberius` | Pure Rust TDS. Watch governance — `praxiomlabs/rust-mssql-driver` is a credible alternative. |
| Oracle | `oracle` (rust-oracle, kubo) | Wraps ODPI-C. Requires Oracle Instant Client on the build host. |
| ClickHouse | official `clickhouse` crate | HTTP interface (8123). Dynamic results streamed via `FORMAT JSONCompactEachRowWithNamesAndTypes`. |
| Redis | `fred` | Modern tokio rewrite of redis-rs. |
| MongoDB | official `mongodb` | Mature, OpenTelemetry support. |
| DuckDB | `duckdb` (official) | Bundled native lib, edition 2024. |
| Cassandra / Scylla | `scylla` | Cassandra-compatible, shard-aware. |
| DynamoDB | `aws-sdk-dynamodb` | Type-safe AWS SDK. |
| BigQuery | `google-cloud-bigquery` (third-party) | No first-party Google SDK. |

If the engine is not listed, open an issue first and discuss the crate choice before writing code.

## 2. Create the crate

Convention: `crates/drivers/<engine>/`.

```bash
cd crates/drivers
cargo new --lib clickhouse
cd clickhouse
```

The crate is named `tablepro-driver-<engine>` in `Cargo.toml`. The library crate name is `drivers_<engine>` (Rust-conventional underscore).

Skeleton `Cargo.toml`:

```toml
[package]
name = "tablepro-driver-clickhouse"
version = "0.1.0"
edition = "2024"
publish = false

[lib]
name = "drivers_clickhouse"
path = "src/lib.rs"

[dependencies]
tablepro-core = { path = "../../core" }
async-trait = "0.1"
clickhouse = { version = "0.15", default-features = false, features = ["rustls-tls"] }
tokio = { version = "1", features = ["rt", "macros", "net", "time"] }
thiserror = "2"
```

Do not add unrelated dependencies. Do not depend on `gtk4`, `libadwaita`, or any other workspace crate except `tablepro-core`.

## 3. Implement the traits

Two traits, both defined in `tablepro-core`:

```rust
#[async_trait::async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn default_port(&self) -> u16;
    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError>;
}

#[async_trait::async_trait]
pub trait Connection: Send + Sync {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError>;
    async fn fetch_columns(&self, table: &str) -> Result<Vec<ColumnInfo>, DriverError>;
    async fn fetch_rows(&self, table: &str, offset: u64, limit: u64) -> Result<QueryResult, DriverError>;
    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError>;
    async fn ping(&self) -> Result<(), DriverError>;
    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}
```

A driver crate exports two types:

- A zero-sized `*Driver` struct that implements `DatabaseDriver`.
- A connection struct (typically wrapping a connection pool from the underlying crate) that implements `Connection`.

Skeleton `src/lib.rs`:

```rust
use async_trait::async_trait;
use tablepro_core::{
    Connection, ConnectOptions, DatabaseDriver, DriverError,
    ColumnInfo, ExecResult, QueryResult, TableInfo,
};

pub struct ClickhouseDriver;

#[async_trait]
impl DatabaseDriver for ClickhouseDriver {
    fn id(&self) -> &'static str { "clickhouse" }
    fn display_name(&self) -> &'static str { "ClickHouse" }
    fn default_port(&self) -> u16 { 8123 }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let client = build_client(opts).await?;
        Ok(Box::new(ClickhouseConnection { client }))
    }
}

struct ClickhouseConnection {
    client: clickhouse::Client,
}

#[async_trait]
impl Connection for ClickhouseConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> { /* ... */ }
    async fn fetch_columns(&self, table: &str) -> Result<Vec<ColumnInfo>, DriverError> { /* ... */ }
    async fn fetch_rows(&self, table: &str, offset: u64, limit: u64) -> Result<QueryResult, DriverError> { /* ... */ }
    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> { /* ... */ }
    async fn ping(&self) -> Result<(), DriverError> { /* ... */ }
    async fn close(self: Box<Self>) -> Result<(), DriverError> { /* ... */ }
}
```

Notes:

- The `id()` is the stable string used in saved connection files. Once shipped, never change it. Pick something obvious and short (`postgres`, `mysql`, `clickhouse`).
- `default_port()` is what the connection dialog pre-fills.
- `DriverError` is a `thiserror` enum in `tablepro-core`. Map underlying crate errors into the variants. Add a new variant only after PR discussion.

`DatabaseDriver` also has defaulted hooks for engines that break an assumption the app otherwise makes. Override one only when the default is wrong for your engine:

- `ddl_is_transactional()`: the structure editor batches DDL into one transaction when true. False for engines that commit implicitly on every DDL statement.
- `reports_rows_affected()`: the inline-edit Save path reads a zero `rows_affected` on an UPDATE or DELETE as another session having changed the row. Return false if the engine cannot produce a count, or every successful save warns about a lost update.

If your engine needs a different SQL spelling for a statement the app builds centrally, add the dialect branch in `core::sql_dialect` (`quote_ident`, `placeholder_for`, `build_update`, `build_order_and_pagination`) rather than rewriting the SQL inside the driver. ClickHouse takes `build_update`'s `ALTER TABLE … UPDATE` branch for this reason.

## 4. Add the crate to the workspace

Edit `linux/Cargo.toml`:

```toml
[workspace]
members = [
    "crates/app",
    "crates/core",
    "crates/storage",
    "crates/drivers/postgres",
    "crates/drivers/mysql",
    "crates/drivers/sqlite",
    "crates/drivers/clickhouse",   # add this
]
```

Run `cargo check --workspace` from `linux/`. The new crate must compile in isolation against `core`.

## 5. Register the driver

Edit `crates/app/src/main.rs`:

```rust
use tablepro_driver_clickhouse::ClickhouseDriver;

fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r.register(Arc::new(ClickhouseDriver));   // add this
    r
}
```

Update `crates/app/Cargo.toml` to depend on the new driver crate. **This step is the one most often forgotten.** The driver crate compiles fine without it; the app simply does not know the driver exists.

## 6. Tests

Two test layers, both required for merge:

**Unit tests** — in `src/lib.rs` `#[cfg(test)]` module. Exercise pure logic: SQL builders, type mappers, error mapping. Do not require a running database.

**Integration tests** — in `tests/integration.rs`. Use [testcontainers-rs](https://crates.io/crates/testcontainers) to spin up a real instance:

```rust
use testcontainers::clients::Cli;
use testcontainers::images::generic::GenericImage;

#[tokio::test]
async fn list_tables_returns_seeded_tables() {
    let docker = Cli::default();
    let image = GenericImage::new("clickhouse/clickhouse-server", "latest")
        .with_exposed_port(8123);
    let node = docker.run(image);
    let port = node.get_host_port_ipv4(8123);

    let driver = ClickhouseDriver;
    let conn = driver.connect(ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        username: "default".into(),
        password: "".into(),
        database: "default".into(),
        ..Default::default()
    }).await.unwrap();

    conn.execute("CREATE TABLE foo (id Int32) ENGINE=Memory").await.unwrap();
    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "foo"));
}
```

Integration tests run in CI on the Linux runner, gated behind `--ignored` so contributors without Docker can still run `cargo test`.

## Checklist for the PR

- [ ] New crate at `crates/drivers/<engine>/` compiles in isolation
- [ ] `DatabaseDriver` and `Connection` fully implemented (no `todo!()` in any method)
- [ ] Crate added to workspace `members`
- [ ] Driver registered in `app::build_registry`
- [ ] App `Cargo.toml` depends on the new driver crate
- [ ] At least one unit test for type / error mapping
- [ ] At least one integration test using testcontainers
- [ ] PR description includes the engine version tested against
- [ ] No new dependencies in `core` or `storage` crates
- [ ] `cargo clippy --all -- -D warnings` clean
