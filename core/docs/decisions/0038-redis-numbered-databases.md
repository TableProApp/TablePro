# 0038: Redis's numbered databases are databases, each a session of its own

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

The Windows database switcher and the Linux editor bar and Open Database… (Linux ADR 0030) follow `SqlDialect::database_layout`. The Redis dialect kept the default, `Single`, its connection listed no databases and its editor session could not move, so neither app offered Redis's numbered databases, which the macOS app switches between. A Redis link reads the database its last `SELECT` chose, and each database's keys are its own.

## Decision

- `RedisDialect::database_layout` is `WithSchemas`: another numbered database is another connection, opened beside the first as for PostgreSQL. No layout is added, since the apps match the enum.
- `list_databases` names each database by its index from `0`, as `SELECT`, a saved connection and a `redis://host/3` URL spell it, marks the connection's own as the default and none as system.
- The count is `CONFIG GET databases`. When the server declines it (`ERR` for a command a managed service removed, `NOPERM` for an ACL), it is at least Redis's 16 and one past every database `INFO keyspace` names and the connection's own, as the macOS plugin counts. A node whose `INFO server` says `redis_mode:cluster` lists `CONFIG GET cluster-databases` (Valkey 9), else database 0 alone. Any other refusal, such as `LOADING`, fails the call.
- The list stops at 10,000, the most a managed service runs (ElastiCache's `cluster-databases`), and keeps the connection's own past it, since one number from the server would otherwise build a menu of any length. A database past it is still reached by its number in the connection or a typed `SELECT`.
- An editor session reports the database its link is on: a `SELECT` the server answered OK, a queued `SELECT` once the `EXEC` that runs it answers OK in its place, database 0 after `RESET`. `DISCARD` and an aborted or broken `EXEC` leave it.
- `use_database` sends `SELECT`, nothing when the link is already there, and refuses inside an open `MULTI` as `Unsupported { DatabaseSwitching }`, since the server would queue it. A cancel before the reply ends the session, as MySQL's `USE` does.

## Rationale

- **`WithSchemas`, not `AsSchemas`.** A link reads one database's keys. Listing every database's keys on one connection takes a `SELECT` around each read, which the macOS plugin does and which would hold every other read on the core's shared workspace link.
- **Numbers, not macOS's `db3`.** The apps compare a listed name with the saved connection's database, which holds the number.
- **No move inside `MULTI`.** A queued `SELECT` moves the link at `EXEC`, after the tab was told it had moved. Neither app moves a tab that holds a transaction; Linux then asks for a commit or a rollback.

## Consequences

- The Windows app shows the switcher on Redis: a pick opens that database as a rail item of its own, and a query tab moves with `SELECT`.
- The Linux app shows the editor bar's menu and Open Database… on Redis through the paths it has for PostgreSQL, with no change to its code.
- The macOS app is unchanged: its plugin keeps its own listing.
