# Adding a database driver

Reviewed against Linux code tip `f9456ba1e` on 2026-10-14. Drivers are static Rust crates under `crates/drivers/`; see [ADR 0001](decisions/0001-no-plugin-system.md). The [active sprint](bookie-0.2-sprint.md) owns engine scope and sequencing. Use [ADR 0007](decisions/0007-type-and-value-preservation.md) as the common type/value and native proof standard. The [documentation entry point](README.md) identifies the owning boards and selective evidence lookup.

## Contracts and crate boundaries

Read the actual traits before implementing a driver:

- [DatabaseDriver](../crates/core/src/driver.rs): identity, defaults, maturity, metadata and transport capabilities, row-count and DDL guarantees.
- [Connection](../crates/core/src/connection.rs): schema-aware reads, bound parameters, transactions, controlled calls, session creation and optional query cursors.
- [Session](../crates/core/src/session.rs): dedicated connection lifetime, transactions, usability and awaited close.
- [Values](../crates/core/src/query.rs), [errors](../crates/core/src/error.rs) and [operation control](../crates/core/src/operation.rs).

Use an existing driver's implementation and manifest as the starting point. The actual trait definitions own the contract; an incomplete example can omit safety hooks. Unsupported defaults do not establish capability support.

Production drivers depend on `tablepro-core`, not GTK, Relm4, policy, MCP, storage, transport or sibling drivers. Shared saved-credential assembly and tunnel ownership belong in `tablepro-transport`; SSH backends belong in `tablepro-ssh`. Policy wraps the raw handle in the composition root.

## Existing libraries

These are the dependencies used by the current drivers:

| Engines | Library |
| --- | --- |
| PostgreSQL, MySQL/MariaDB, SQLite | `sqlx` with engine-specific features |
| SQL Server | `tiberius` (workspace crates.io `0.13`) |
| ClickHouse | `clickhouse` plus the current dynamic-result implementation |
| Redis | `redis`, including the workspace's vendored patch |
| MongoDB | `mongodb`, including the workspace's vendored patch |
| DuckDB | `duckdb`, behind the optional `duckdb` feature |

Review engine/library proposals against [driver maturity](adding-drivers.md#order-the-engines-were-added), dependency policy and license requirements. Upstream macOS plugins are behavior references; they do not introduce a Linux runtime plugin ABI.

## Implementation checklist

1. Create `crates/drivers/<engine>/`. Package name is `tablepro-driver-<engine>`; existing library names use `drivers_<engine>`. Reuse workspace versions/lints and review dependencies with `deny.toml`.
2. Implement the current traits. Preserve SQL NULL versus unsupported/non-NULL values; unsupported values must remain `Value::Undecodable` or be refused, rather than becoming NULL. Map errors to typed `DriverError` variants.
3. Bind values and quote identifiers for the actual dialect. Carry schema and table identity separately. Declare generated/identity metadata accurately; include composite keys and real affected-row behavior.
4. Declare maturity and capabilities honestly. Controlled calls need a bounded operation, confirmed server cancellation or an honest unknown outcome with retirement. Do not claim Stop support from a dropped client future.
5. If supporting sessions, prove settings/temp tables/transactions stay on one physical connection, lost sessions never fall back to a pool, and close is awaited. New methods must be forwarded through policy and owning wrappers.
6. Keep dial endpoints separate from TLS/Kerberos service identity. Test wrong CA/hostname, no plaintext fallback and tunneled verification per engine. Initialize the shared crypto provider in test composition roots that link multiple TLS drivers. Do not load saved secrets inside a driver.
7. Add the workspace member and dependencies in both composition roots. Register in [app::build_registry](../apps/linux/app/src/lib.rs) and [agentd::build_registry](../crates/agentd/src/main.rs). Apply matching feature gates where native build cost requires them.
8. Update maturity/connection documentation and the user-facing changelog. Register tests and runner ownership before claiming integration.

## Tests and evidence

Use current testcontainers `AsyncRunner` examples in existing drivers. Integration crates need the test-only Clippy allowances specified in `AGENTS.md`; fixture tests are ignored in the fast tier and executed by their dedicated layer.

From the repository root, a focused engine fixture command is:

```bash
cargo test -p tablepro-driver-<engine> --test integration -- --include-ignored --test-threads=1
```

Cover native stored type/value, invalid neighbors, bound parameters, consumer round trips, late stream failures, server loss and subsequent handle usability. Mocks cover dispatch/denial; real engine assertions establish server behavior. Record initial failing behavior before applying a bug fix.

Review `scripts/ci-local.sh`, `scripts/test-layers.json`, the TLS runner, change-test mapping, ignored-test inventory and hosted workflow package lists for a new crate. Register isolated GTK/keyring tests where needed. Run affected layers selected through [the validation playbook](validation-playbook.md); regenerate the ignored-test inventory. Optional-feature build evidence is separate from default-workspace success.

Return an exact SHA, commands, report paths, retained sanitized evidence and unrun gates. Driver maturity, a fixture pass, package qualification and release approval are separate claims.

## Driver maturity

Every registered driver reports a `DriverMaturity` (`Stable` or `Experimental`). The Connect dialog shows Experimental as a subtitle so users are not surprised by missing write or transaction paths. These are driver declarations, not release approval; see [current acceptance](bookie-0.2-sprint.md).

| Driver | Maturity | Connect | Browse | Query | Writes | Params | `begin` / MCP preview | Notes |
|---|---|---|---|---|---|---|---|---|
| PostgreSQL | Stable | yes | yes | SQL | yes | yes | yes | Five TLS modes; release fixture covers certificate verification and SSH routes |
| MySQL | Stable | yes | yes | SQL | yes | yes | yes | DDL not transactional; driver TLS fixture |
| SQLite | Stable | yes | yes | SQL | yes | yes | yes | File-based |
| SQL Server | Stable | yes | yes | SQL | yes | yes | no interactive begin | Tiberius; custom CA implemented; Verify Ca and Verify Full are identical; server cancellation unsupported |
| ClickHouse | Stable | yes | yes | SQL | yes | yes | no | Waits for asynchronous mutations to finish; no row counts; driver TLS fixture |
| Redis | Experimental | yes | DBs / SCAN | Redis CLI | via query | no | no | Single host/port endpoint only; Sentinel and Cluster topologies are unsupported; driver TLS fixture; Verify Ca behaves as Verify Full |
| MongoDB | Experimental | yes | collections | find / aggregate | insertOne / deleteMany / drop; keyed grid edits use bound values | no | no | TLS fixture coverage; Verify CA behaves as Verify Full; integration coverage includes browse, find, aggregate, stale-edit and stale-delete checks |
| DuckDB | Experimental | yes | yes | SQL | yes | yes | no | Cargo feature `duckdb`; CSV/TSV/JSON/Parquet files; bundled JSON/Parquet; explicit optional CI |

### Maturity rules

1. Default maturity is `Stable`. Override only when a path users expect is missing or dialect-limited.
2. Do not register a driver that always fails at connect.
3. DuckDB stays behind `--features duckdb` for compile size, not maturity.
4. Raising a driver to Stable means browse, the engine's query dialect, common writes, and CI integration coverage are in place.

Transport and TLS behaviour per driver is tracked in [connections.md](connections.md).

### Order the engines were added

ClickHouse (Stable), Redis (Experimental), DuckDB (Experimental, `--features duckdb`), MongoDB (Experimental). SSH jump-host chains belong in `crates/ssh` as sequential tunnels, not in drivers.
