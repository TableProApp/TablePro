# 0014: Live-server tests on the Windows runner

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The interop tests reached a server only for PostgreSQL (`NoticeTests` and the SSH tests over `ci/ssh-postgres.ps1`). MySQL, SQL Server, ClickHouse, Cassandra, MongoDB and Redis ran on Windows only through the core's unit tests, and DuckDB through SQLite-shaped file tests, so nothing showed that the FFI connects to them, pages a table, shows their values as the Linux grid does and saves a row on Windows. The core's value corpus, the values each engine's suite reads back with the text the grid shows, was Rust code inside each driver's integration target, which the .NET tests could not read. Hosted Windows runners run no Linux containers, so the core's Docker fixtures do not start there.

## Decision

### Tests

- `tests/TablePro.Interop.Tests/Live` holds one class per engine, through the public interop API only. A SQL engine's class (`SqlEngineTests`) lists a new table in the catalog, pages it, counts it and reads its structure; writes each corpus column into a table of its own and reads every value back through `ReadTablePageAsync`, as a table tab does, and a plain `SELECT` in a `QueryEditor`, as a query tab does, comparing `GetCellText` with the text the corpus names, every wrong value in one failure; and saves an update, an insert and a delete through `TableEditor` and reads the rows back.
- MongoDB's class does the same with a collection and the document of every BSON type the driver's own tests read, where a table tab shows a binary field and a field of nulls as the extended JSON it edits them as. Redis's writes a key of each type from the editor, lists them there, reads each through `KeyReader` as a key tab does, and changes and deletes keys, with a key's expiry.
- The corpus is one home for both sides: `core/crates/test-support/corpus/<engine>.json`, which the Rust conformance cases read through `ValueCorpus` and the test project copies beside its assembly. A column marked `only` belongs to one flavour of a file two engines share (MySQL and MariaDB).
- A class whose server is not there skips. `ci/live-servers.ps1` names each server in `TABLEPRO_TEST_LIVE_<ENGINE>_PORT`, `_USER` and `_PASSWORD`.

### Servers

Each one is set up the way that measured fastest and held on `windows-2025`:

| Engine | How it runs | Setup |
| --- | --- | --- |
| MySQL 8.4 | The image's install, a new data folder (`--initialize-insecure`), a password user | 10 s |
| SQL Server 2022 Express CU1 | `core/crates/drivers/mssql/tests/windows/sql-server.ps1 -Install -SaPassword`, its certificate verified with the CA file the script writes | 4 min 39 s |
| MongoDB 7.0 | The image's service, started | 9 s |
| Redis 8.10.3 | The redis-windows msys2 build, pinned by SHA-256 | 2 s |
| Cassandra 4.0.21 | The Apache tarball on the image's Java 11, its java command written out with `disk_access_mode: standard` | 46 s |
| ClickHouse 26.8 LTS | Its Linux binary in a WSL 1 distribution imported from the Ubuntu base tarball | 14 s |
| DuckDB | In process: no server, so it runs in every Windows job and on macOS | none |

- The `live` job in `windows.yml` runs them on `windows-2025` beside the x64 test job, one step per server, then `dotnet test --filter-namespace TablePro.Interop.Tests.Live --fail-skips on`, so a server that did not start fails its tests rather than skipping them. It reads the x64 job's Cargo cache and saves none. `ci.yml` calls `windows.yml` only when the `windows` suite changed.
- Arm64 runs DuckDB only. Its image has no PostgreSQL, MongoDB or SQL Server, SQL Server installs on x64 alone, and every driver is the same Rust code on both.

## What the runner showed

Probes on `windows-2025` (runs 44241847132, 44242839754 and 44243471366):

- Cassandra 5.0.9 stops at its startup check on Windows ("The native library could not be initialized properly"): it links the C library as on Linux, and 4.1's source has no Windows native library either. 4.0.21, which still has one, starts in about 40 s.
- WSL 1 runs a Linux binary on the runner and its listener answers on 127.0.0.1. ClickHouse's `clickhouse-common-static` binary needs glibc's loader, so it runs in the Ubuntu base distribution (a 4 s import) and not in Alpine's minirootfs; the full Ubuntu WSL image took 71 s to fetch and import.
- SQL Server 2022 Express RTM installed in 2 min 36 s with SQL logins; with CU1, as the core's script installs it, 4 min 39 s.
- MySQL's `--initialize-insecure` took 5 s and its start 2 s. The Redis build started in under a second.
- The first live run (44244847194) found the grid showing an unreadable value as an empty cell, where the Linux grid shows `<unreadable money>`: the FFI kept no text for it. The core now keeps the type's name for the grid's window ([0003](0003-data-grid-control.md)).
- Java started with its output redirected shares the step's console and stopped when the step ended, so Cassandra refused the tests' connections (run 44249651260); started on a console of its own it runs to the end of the job.
- The core lists no Redis keys through the FFI (the Linux sidebar's listing lives in the Linux app), so the Redis test lists them with `KEYS` in the editor.
- Run 44256128478 passed all 21 live tests in 48 s, after 7 min of server setup.

## Rationale

- One corpus file read by both sides: a copy in C# would drift from the one the Linux suites fix decoders against.
- Native servers where they exist, WSL 1 only for ClickHouse: no VM, no image pull, and the runner reaches a WSL 1 listener on 127.0.0.1.
- A separate job keeps the x64 job's time and its UI tests as they were, and costs one runner when Windows changed: about 7 minutes of servers, then the build, which the x64 job's cache shortens.

## Consequences

- Cassandra on Windows is 4.0, the older of the two releases the core's fixtures run; 5.0 stays covered on Linux.
- The Linux suites' guide (`linux/docs/testing.md`, Value corpus) still names the corpus as Rust builders; it moves to the JSON files after Linux 0.1.0.
- A new engine with a corpus adds its file to `corpus/`, a `ValueCorpus` variant, a class here and a step in `live-servers.ps1`.
