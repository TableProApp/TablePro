# 0028: A window holds several sessions in one tab view

- **Status**: Accepted
- **Date**: 2026-10-27

## Context

Under [0012](0012-window-per-session.md) a window holds at most one connection session. Working on two databases means two windows, and the saved connections and their groups show only on the picker, which goes once a window connects. Users who come from clients that list every connection in one tree, with tabs of several connections side by side, ask for that flow.

0012 rejected a window that swaps one session in place, because every part that read the session had to be reset at each switch and a late reply could land in the next session. It also rejected one session service shared by every window.

## Decision

A `SessionWindow` holds any number of sessions, each under its own `SessionClaim`, in one `WorkspaceShell`. The shell owns what a window has once: the header bars, the sidebar, the one `AdwTabView` every session's tabs share, the assistant's column and the toasts. Each session keeps its own `Workspace`, which holds what it held before, and a tab never changes session. The sidebar is a tree of the saved connections in their groups, with the schemas and tables of each open session under its connection.

## Rationale

- What 0012 protects still holds one level down. A workspace never changes session, so it has nothing to reset, and its teardown order is the same. Tabs already took their session when they were built.
- Sessions are not shared across windows. The registry still keeps a key in one window, and a connection open elsewhere brings that window forward.
- The session whose tab is in front speaks for the window: its actions are on the window's map, its banners show, and its level is the Safe Mode the menu ticks. Coming to the front is deferred out of the tab view's signal, so it never enters a workspace that is handling input.
- A schema's rows in the tree are a slice of the session's own sidebar list, so the index built off the GTK thread and the rows made on demand keep serving catalogs of 50,000 tables.

## Consequences

- This supersedes 0012 for what a window holds. The application, the subclasses and the input queues it decided stay.
- A connection opened from the tree connects beside the window's sessions. A failure says so in a toast instead of the failed page, which only the window's first connect shows.
- The window's close asks each session's prompts in turn. A disconnect asks only that session's tabs, and the last one returns the window to the picker.
- The restore record still lists keys without their window, so a restore opens a window per session.

## Alternatives considered

**A window per session with a strip to switch between them.** Keeps 0012 whole, but the tabs of two connections are never side by side.

**A tab bar per session in one window.** Smaller, but switching connection hides the other connection's tabs.
