# Linux docs

The reference for working on the Linux app. Start with [ARCHITECTURE.md](../ARCHITECTURE.md) for the crate graph and [CONTRIBUTING.md](../CONTRIBUTING.md) for the build; [features.md](features.md) says what is built, and the repository's [ROADMAP.md](../../ROADMAP.md) what is not.

## Guides

| Guide | What it covers |
|---|---|
| [adding-drivers.md](adding-drivers.md) | Adding an engine as a crate: the client library, capabilities, `Connection`, writes and editor sessions |
| [error-handling.md](error-handling.md) | The error types each layer returns, their categories, and the text and logs the app makes of them |
| [state-management.md](state-management.md) | Where the application, window, workspace and tab state lives, and the rules every view follows |
| [storage.md](storage.md) | Which store holds which data: files, GSettings, the Secret Service and SQLite |
| [testing.md](testing.md) | The test suites, the conformance and Docker tests, the manual passes and the CI workflows |
| [toolkit-workarounds.md](toolkit-workarounds.md) | Each place the app steps around a GTK, libadwaita, GtkSourceView, IBus or gtk-rs defect, and when it can go |
| [troubleshooting.md](troubleshooting.md) | For users: saved passwords, SSH, Kerberos, logs, crash reports, bug reports and downgrades |
| [regression-tests.md](regression-tests.md) | The tests that guard each critical audit finding |
| [features.md](features.md) | What the app does today, area by area |
| [releasing.md](releasing.md) | The setup before the first release, the 0.1.0 release criteria, a release, a packaging fix and a fix release |
| [po/README.md](../po/README.md) | Marking strings for translation and generating the template |

## Drivers

| Engine | Page |
|---|---|
| PostgreSQL | [drivers/postgresql.md](drivers/postgresql.md) |
| MySQL and MariaDB | [drivers/mysql.md](drivers/mysql.md) |
| SQL Server | [drivers/sql-server.md](drivers/sql-server.md) |
| ClickHouse | [drivers/clickhouse.md](drivers/clickhouse.md) |
| Cassandra and ScyllaDB | [drivers/cassandra.md](drivers/cassandra.md) |
| SQLite | [drivers/sqlite.md](drivers/sqlite.md) |
| DuckDB | [drivers/duckdb.md](drivers/duckdb.md) |

## Decisions

The architecture decision records, with a summary of each, are indexed in [decisions/README.md](decisions/README.md).
