# 0030: Another database of a connection is a session of its own in the window

- **Status**: Accepted
- **Date**: 2026-10-30

## Context

A session is one connection to one database ([0028](0028-sessions-share-a-window.md)). The editor bar lets a query tab move its own editor session to another of the server's databases. The window's sidebar, its catalog and completion still read the database the connection opened, so after a move the tab's tables are missing from both. On SQL Server and PostgreSQL, where a database holds schemas, completion offers nothing.

The macOS app keeps a connection per database where the engine needs one and points the window at the database of the tab in front: its sidebar shows that database, and a tab bound to another one is hidden until the window returns there (`BrowseCursorCoordinator`, `QueryTabManager.reconcileVisibleContainer`).

[0012](0012-window-per-session.md) rejected a session that changes in place under its parts, and 0028 keeps a tab on the session it was built with.

## Decision

Each other database of a connection the user opens is a sibling session in the same window, with a workspace of its own, made with `Session::open_in_database`. The sidebar shows each open database of a connection as a branch under it. A query tab moved to a database from the editor bar opens or reaches that database's session, and the window follows it there.

## Rationale

- **No session changes under its parts.** A sibling is another session, so what 0012 and 0028 protect holds: a workspace never changes database, and a tab never changes session. A table opened from a database's branch is built on that database's session.
- **The catalog is the database's own.** Each sibling's catalog lists its database, so the sidebar, completion and Show CREATE TABLE are right on every engine, the ones whose databases hold schemas included.
- **One way in.** A sibling joins the window as any session does, so its tabs, its unsaved edits, its banners and its teardown follow what a connection's already do.
- **The same secret and no prompt.** A sibling opens as a reconnect does, through the window's connector and the stored secret (#3900).

## Consequences

- The registry keeps a window's key per saved connection; a sibling is keyed by the connection and its database, so the same database of a connection never opens twice.
- The sidebar's connection row gets Open Database…, from the server's databases, and each open database is a branch the user can close.
- A tab names its database beside its connection, as "orders (prod, analytics)", while another database of the connection has a tab in the bar.
- The restore record keeps each window's siblings with their tabs.
- The editor bar's move runs on the tab's own editor session as before; the window following it is the sidebar selecting that database's branch and completion reading its catalog.
- A file connection has no other database.

## Alternatives considered

**One session that follows the tab in front, as macOS's window does.** Every part reading the session would have to be reset at each tab switch, which 0012 rejected, and a table tab built for one database would run on another.

**Hide the tabs of the other databases, as macOS does.** 0028 chose tabs of several sessions side by side over a strip that hides them; a database is a session here, so its tabs show beside the others with its name in the title.

**Only completion follows the tab.** Smaller, but the sidebar and every other tab stay on the connection's database, which is the gap this closes.

## Plan

In order, each its own pull request: the sibling session (#3900); the registry key and a sibling joining the window; Open Database… and the database branches in the sidebar; the editor bar's move reaching the database's session, with completion on its catalog; tab titles; the restore record.
