# BookiE - product overview

> [NEEDS REVIEW] Draft written on 2026-10-11 from the repo and its README. A maintainer review is pending.

## What it is

BookiE is a native Linux database client. A person runs it on their machine, opens saved connections (optionally through SSH), browses tables, writes SQL, and can expose the same governed path to an MCP agent through `bookie-agentd`. It was previously called TablePro on this branch. Every shipped feature works without an account, license key, subscription, paid tier or remote entitlement check.

## What people do today instead

Alternatives include other desktop database clients, vendor consoles, and command-line tools such as `psql` or `mysql`. BookiE's product bet is to combine a local GTK workflow with one governed and audited database path for the GUI and MCP consumers.

## Vision

Stay a Linux-only native client. Finish BookiE 0.2.0 as a development release for the Arch and Hyprland target, with hotfixes to follow. Keep drivers compiled in. Store persistent credentials in Secret Service and issue headless MCP tokens once through an explicit output path. Keep MCP, the GUI and the headless daemon on one governed SQL path.

## Current state (as of 2026-10)

- **Live:** saved connections, SSH tunnels, browse and SQL tabs, structure editing, inline row changes, query history, policy checks, audit records, MCP access, `bookie-agentd`. Installable 0.1.5 packages on Debian (GNOME 50 libraries) and Arch. PostgreSQL is the furthest-along engine.
- **In progress:** B3 type/value consumer coverage, B4 transport and session acceptance, installed desktop qualification, and progressive server-cursor paging. Core, PostgreSQL and PolicyGuard cursor support exists; SQL editor integration remains ([ADR 0011](docs/decisions/0011-paged-query-results.md)).
- **Left out of 0.2.0:** Flatpak and Flathub, a web UI, runtime driver plugins, accounts or paid tiers.

## Users / personas

The roster is in [docs/personas.md](docs/personas.md). The primary persona is the local DBA or developer who runs BookiE on their own Linux machine.

## Key capabilities

- Governed SQL through `PolicyGuard` (classify, rules, approval, mask, execute, audit). See [specs/governed-sql/spec.md](specs/governed-sql/spec.md).
- SSH transport and host-key trust. See [specs/ssh-transport/spec.md](specs/ssh-transport/spec.md).
- Secret Service credentials (absent vs keyring failure). See [specs/secret-storage/spec.md](specs/secret-storage/spec.md).
- Native GTK workspace: browse, SQL editor, named parameters, favorites, Open Quickly.
- Headless MCP server with token scopes and connection allowlists. Those checks never replace `PolicyGuard`.
- Static drivers for PostgreSQL, MySQL/MariaDB, SQLite, SQL Server, ClickHouse, Redis, MongoDB, and optional DuckDB.

## Non-goals

- Not a hosted SaaS, multi-tenant service, or account-gated product.
- Not a cross-platform or browser UI.
- Not a runtime plugin host for database drivers.
- Not a replacement for the engine's own admin console.
- Not a Node or web application stack.

## Related

- [Active sprint](docs/bookie-0.2-sprint.md)
- [README](README.md)
- [Architecture](ARCHITECTURE.md)
- [ADRs](docs/decisions/README.md)

## Success metrics

- North Star: a local user can open a saved connection and run governed SQL without creating an account.
- Installable packages exist for the documented distros without a license check.
- Every GUI, MCP and agent database handle is a `PolicyGuard`.
- Denied, failed, cancelled and timed-out operations still write a terminal audit state.
