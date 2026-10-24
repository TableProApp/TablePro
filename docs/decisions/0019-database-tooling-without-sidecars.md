# 0019: Database tooling without sidecars

- **Status**: Accepted; PostgreSQL backup and restore are wired into the app. Their cancellation and unknown-outcome review was tracked in the now-closed [#1043](https://github.com/cozyGarage/BookiE/issues/1043). An unknown restore outcome still blocks governed writes until reconciled; the app has no in-app reconciliation action yet ([#947](https://github.com/cozyGarage/BookiE/issues/947)). File conversion, schema migrations and backup/restore for other engines remain post-0.2.0 work.
- **Date**: 2026-10-16

### Clarification (2026-10-20)

The accepted decision does not set a release target for the remaining tools. PostgreSQL backup and restore are implemented; follow-up work remains subject to post-0.2.0 selection and acceptance.

The implementation uses the shared transport and SSH route to create the client-tool endpoint, then supervises the vendor process in `crates/dump`; it is not specific to the system OpenSSH backend. The current process does not apply Landlock, so the conditional filesystem restriction in Decision 3 is not implemented and must not be treated as a shipped security boundary.

## Context

Users want file conversion, schema migrations and logical backups next to browsing and editing. One proposal was to keep performance-critical paths in Rust and ship Go binaries as sidecars for this tooling. A sidecar adds a second toolchain to every package build, a second supply-chain review that `deny.toml` does not cover, 10 to 40 MB per binary, and a process boundary that needs its own credential handling. [ADR 0001](0001-no-plugin-system.md) already rules out loading third-party code, and [ADR 0015](0015-database-snapshots.md) covers native snapshots, not portable dumps.

## Decision

BookiE ships no sidecar binaries. Each tool uses the narrowest mechanism that already fits the architecture.

1. **File conversion uses the DuckDB driver.** The driver already opens CSV, TSV, JSON and Parquet files without downloading extensions. Conversion reads one of those files and writes CSV, JSON or Parquet with DuckDB `COPY ... TO`. Paths come from the file chooser, are passed as escaped literals, and an existing output file is replaced only after the user confirms. The work runs off the GTK thread with an `OperationControl` (ADR 0005).
2. **Schema migrations use `refinery` behind `PolicyGuard`.** `refinery` (MIT) supplies ordering, checksums and the history table only. BookiE implements its transaction and query traits on a guarded connection, so `refinery` never opens a connection of its own. Every migration statement is classified, checked against the environment's rules, approved where required and audited like any other statement (ADR 0016). Read-only connections and agent principals are refused. Engines are those `refinery` supports and BookiE ships: PostgreSQL, MySQL and MariaDB, SQLite and SQL Server.
3. **Logical backup and restore call the vendor client tools.** PostgreSQL uses `pg_dump` and `pg_restore`. MySQL and MariaDB support is a later extension using `mysqldump` or `mariadb-dump` and the matching client. Other engines wait for a tested design. The tools are user-installed optional dependencies, never bundled in the Arch or Debian packages. Each run follows the rules of the system OpenSSH transport in `crates/ssh`:
   - The binary is resolved once to an absolute path and its version is checked; `pg_dump` must be at least the server's major version.
   - The child starts with a cleared environment and is killed when its operation is cancelled or dropped.
   - A cancelled or dropped dump removes its partial output. Restore dispatch begins when `pg_restore` starts; any failure after that point has an unknown outcome, is audited as unknown and blocks governed writes on that connection. The durable outcome remains unresolved after reconnect, while other connections remain available; the app does not yet provide an in-app reconciliation action. Cancellation before dispatch remains cancelled.
   - Passwords never appear in arguments. PostgreSQL reads a 0600 `PGPASSFILE`; future MySQL support will use a 0600 `--defaults-extra-file`. Both are created in `$XDG_RUNTIME_DIR` and removed when the run ends.
   - Host and port come from the transport endpoint, so SSH tunnels and TLS settings apply as they do for the driver.
   - Where the kernel supports Landlock, the child can write only the chosen output path.
   - Output shown to the user is bounded and has connection details removed.
4. **Backup and restore are administrative operations.** They go through `PolicyGuard` as one operation each, with an ADR 0010 intent before and an outcome after, and no paths, database names or secrets in audit events. Restore replaces data, so it is refused on read-only connections and for agent principals, and needs a confirm dialog that names the target. These tools are not exposed through MCP.
5. **Flatpak bundles clients or omits the feature.** A Flatpak build never uses `flatpak-spawn --host`, which escapes the sandbox.

## Rationale

The DuckDB driver and the OpenSSH supervisor already exist, are tested and pass `deny.toml`. The vendor dump tools are the only way to get native-fidelity dumps without maintaining a dump writer per engine. Keeping `refinery` behind the guarded connection keeps one enforcement point for every statement BookiE runs.

## Consequences

- Backup and restore need the vendor tools installed; the panel says which tool is missing or too old.
- Migrations run statement by statement through the policy path, so they are slower than a tool with its own connection, and a statement the classifier cannot parse needs approval.
- `refinery` needs the dependency review in `deny.toml`.
- Each engine needs Docker tests: a dump restored into a fresh database matches the source rows, a migration set applies once and is recorded, and refusal tests cover read-only connections, agent principals, missing tools and old tool versions.
- This narrows the `pg_dump` alternative in ADR 0015: argument passwords are avoided, and the tools are optional dependencies rather than required ones. ADR 0015 snapshots remain the fast in-server path.

## Alternatives considered

- External migration-tool sidecars: a second toolchain and audit pipeline, larger packages, and separate database connections that would bypass `PolicyGuard` unless the tools can use BookiE's guarded connection.
- Writing dump and restore in Rust per engine: complete control, but a large writer to maintain per engine and lower fidelity than the vendor tools.
- Running tools on the host from Flatpak: escapes the sandbox.
