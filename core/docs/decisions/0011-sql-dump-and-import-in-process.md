# 0011: SQL dumps and SQL file imports run in process

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

The Linux app's first release adds Export Database, which writes a whole database or one schema, structure and rows, to a `.sql` or `.sql.gz` file, and Import SQL File, which runs such a file against a connection. The Windows app will offer the same. The macOS app has both an in-process SQL export and import, and a separate Backup Dump that runs `pg_dump`, `mysqldump`, `mongodump`, `sqlite3` and `sqlpackage`.

So either the core writes and reads the file itself, from the drivers it already has, or the apps run each engine's own tool. Measured on 2026-11-05 in containers of the target systems:

| System | `pg_dump` | `mysqldump` by default | `sqlite3` | DuckDB, ClickHouse, SQL Server tools |
|---|---|---|---|---|
| Ubuntu 26.04 | 18.6, the archive's only major | MySQL 8.4.11 | 3.46.1 | not packaged |
| Ubuntu 26.10 | 18.6 | MySQL 9.7.2 | 3.53.4 | DuckDB 1.5.5 only |
| Fedora 44 | 18.6 | MariaDB 11.8.8 | 3.51.2 | not packaged |
| Fedora 45 | 18.3 | MariaDB 12.3.2 | 3.53.4 | not packaged |

## Decision

The core writes the dump and runs the file in process, through the connection's own driver: `tablepro_core::dump` (`write_dump`, each driver's `read_dump_catalog` and `DumpDialect`) and `tablepro_core::import::run_sql_import` with the incremental `ScriptReader`.

## Rationale

- **The tools are not there to call.** None is installed with the app. Ubuntu lets one MySQL family in at a time (`mysql-client-core` conflicts with `mariadb-client`), Fedora installs MariaDB's under `mysqldump`, and neither archive packages a tool for DuckDB, ClickHouse or SQL Server. Windows ships none of them.
- **They refuse the servers users have.** `pg_dump` refuses a server newer than itself ("aborting because of server version mismatch", measured with 18.3 against 19beta1), and the distributions carry one major. MySQL 8.4's `mysqldump` fails against MariaDB 11.8 on `COLUMN_STATISTICS`; `mariadb-dump` against MySQL 8.4 writes a file MySQL will not load (ERROR 3105 on a generated column); a default `mysqldump` of a GTID server will not load into another database of that server (ERROR 3546).
- **Three engines have no plain SQL dump tool.** `sqlpackage` writes `.bacpac` and `mssql-scripter` was archived in 2024; ClickHouse's `BACKUP` writes to the server's storage; DuckDB's `EXPORT DATABASE` writes a directory, refuses a self-referencing foreign key and leaves triggers out.
- **The connection would not carry over.** The Linux SSH forward is a Unix socket, over which libpq ignores `sslmode`; neither MySQL client can override the server name a certificate is checked against; on Windows the in-process forward listens only for the app itself ([0009](0009-in-process-ssh-on-windows.md)). The password would go through `PGPASSWORD`, which PostgreSQL does not recommend, or `MYSQL_PWD`, deprecated in MySQL 8.4.
- **The Flatpak cannot run them.** A host binary needs `--talk-name=org.freedesktop.Flatpak`, and Flathub does not accept apps that rely on host components for a core feature. Bundling means building PostgreSQL and a MySQL-family client into the Flatpak, one version for every server.
- **The file loads with the engine's own client anyway.** The dump follows `pg_dump` plain format and `mysqldump`'s header, `DELIMITER` blocks and `GO` batches, so `psql`, `mysql`, `sqlcmd`, `sqlite3` and `clickhouse-client` read it as well as TablePro does.

## Consequences

- A dump carries what each driver reads, not everything the engine has. PostgreSQL leaves out ownership, grants, policies, rules, publications and event triggers, as `pg_dump --no-owner --no-acl` would leave the first two; MySQL leaves out events; ClickHouse leaves out user-defined functions, which belong to no database. The Linux README lists them.
- Tables are read one after another, each in a read-only transaction of its own, not at one snapshot, so a database written to during the export can give a file whose tables disagree.
- The import reads files the native tools write: pg_dump's `COPY ... FROM stdin` rows run as INSERTs, its `\restrict` lines are passed over, and another psql command is refused with its name. A MySQL dump that holds raw binary, as `mysqldump` writes without `--hex-blob`, is not UTF-8 and is refused at its line.
- The macOS Backup Dump, which runs the tools, stays a separate feature. A tool-based backup for the `.deb` and `.rpm` builds can come later beside this one; it would not replace it.

## Alternatives considered

- **Run the engine's tool where it is installed, the core's writer elsewhere.** Two outputs for one menu item, chosen by what happens to be on `PATH`, and the version and family checks the macOS Backup Dump needed about 3,500 lines of Swift for.
- **Bundle `pg_dump` and `mysqldump` in the Flatpak.** One version for every server, PostgreSQL's and MariaDB's sources built into every release, and nothing for the other engines or for Windows.
- **`COPY` in the PostgreSQL dump.** Faster to load, but only psql reads `COPY ... FROM stdin` from a file; multi-row INSERTs with a column list load through every client and driver.
