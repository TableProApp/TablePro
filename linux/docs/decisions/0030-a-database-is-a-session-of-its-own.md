# 0030: A query tab's database, and another database as a session of its own

- **Status**: Accepted
- **Date**: 2026-10-30

## Context

A session is one connection to one database ([0028](0028-sessions-share-a-window.md)). A query tab can run in another of the server's databases, through the editor bar or a `USE` the user types. Engines get there in different ways: MySQL, MariaDB and SQL Server move a live session with `USE`, ClickHouse names the database in every request, Cassandra moves its keyspace, MongoDB's shell keeps a current database, and PostgreSQL binds the database when the connection opens. The window's sidebar and the completion catalog read the database the connection opened.

[0012](0012-window-per-session.md) rejected a session that changes in place under its parts, and 0028 keeps a tab on the session it was built with.

## Decision

A query tab keeps its database, and its own editor session goes there. `EditorSession::use_database` moves a live session by the engine's own means; where the engine binds the database at connect, the driver refuses it and the tab gets an editor session opened in that database (`EditorSessionOptions::database`). A session reports the database a `USE` left it in, and the tab follows. The tab never changes session: its workspace, Safe Mode and teardown stay its connection's.

What the window shows of another database is a sibling session, `Session::open_in_database`: the same server and login, opened as a reconnect is. It joins the window with a workspace and a sidebar row of its own, from Open Database… on a connection's row, or when a tab moves to that database. Completion in a moved tab reads the sibling's catalog.

The connection's open session owns its siblings, open or still opening. They take its Safe Mode level, and a level that needs a reconnect opens them again beside it. Its disconnect and its window's close take them through the same teardown, and a sibling still opening holds its claim there, so none outlives the connection or keeps its key.

## Rationale

- **A tab keeps what it built.** A `USE` keeps the tab's temporary tables and settings. The database menu waits while the tab holds a transaction, so a move never rolls one back.
- **The tab's session does not wait on the window's.** A PostgreSQL tab opens in its database over its own connection, with the secret the connection already holds, so a restored tab or a lost connection reopens there without a sibling.
- **The catalog is the database's own.** A sibling lists its own database, so the sidebar and completion are right on engines whose databases hold schemas. Until it opens, completion reads the connection's catalog where the server's databases are its schemas (MySQL, ClickHouse, Cassandra, MongoDB) and offers no tables where they are not.
- **No session changes under its parts.** A sibling is a session like any other, so 0012 and 0028 hold.

## Consequences

- A sibling opens with the stored secret and never prompts; one that cannot open says so in a toast and the tab still runs in its database.
- The registry keys a sibling by its connection and database, so a database opens once per window.
- Deleting a connection deletes its siblings' saved tabs and drafts, found by the connection's part of their names.
- A tab names its database in its title when it is not the connection's.
- The workspace record keeps a tab's database, and a restore reopens a connection's open databases beside it once it has joined.

## Alternatives considered

**One session that follows the tab in front.** Every part reading the session would reset at each tab switch, which 0012 rejected.

**Every move opens a new editor session.** One path for every engine, but a `USE` engine would lose its temporary tables and settings at each move.

**A PostgreSQL tab runs on its sibling's connection.** The tab would depend on a window session the user can close, and a password typed only for the connection could not open it.
