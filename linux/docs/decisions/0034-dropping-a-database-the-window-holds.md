# 0034: Dropping a database the window holds open

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

The sidebar now creates and drops databases and schemas (core [0013](../../../core/docs/decisions/0013-catalog-operations.md)). On PostgreSQL and SQL Server another database is a sibling session of its own ([0030](0030-a-database-is-a-session-of-its-own.md)), and both servers refuse to drop a database any session is connected to. A sibling's close was fire and forget, so a drop sent after it raced the sibling's own connections. On MySQL and ClickHouse the server drops the database a session is in and leaves the session pointing at nothing.

## Decision

The sidebar never offers to drop the database a session opened, its default schema, or one the engine keeps for itself. Drop Database on PostgreSQL and SQL Server is on the connection's row, picked from the server's databases, and on a sibling's row. Once the user confirms, the window runs the sibling's own disconnect prompts, closes it and waits for its connections to close, then the connection's own session sends the DROP. A prompt answered Cancel drops nothing. Other sessions on the database, the user's own query tabs there included, make the server refuse unless Close Other Connections is on.

A session that reconnects into a database that is gone parks with "does not exist on the server" rather than retrying. A database created on PostgreSQL or SQL Server opens beside the connection, so it shows.

## Rationale

- **The prompts a disconnect asks still hold.** Taking a sibling down for a drop loses its tabs as a disconnect does, so it asks what a disconnect asks.
- **The server decides about other sessions.** The app closes only what it opened for that database; closing anyone else's is the user's choice, made with the switch.

## Consequences

- Dropping a database closes its sibling's row and tabs and forgets it, so it is not restored.
- Schemas with nothing in them get a sidebar row, and the schema list is read again after a create or drop, so a new schema shows at once.
