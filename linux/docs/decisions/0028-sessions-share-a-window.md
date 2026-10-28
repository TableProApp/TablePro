# 0028: A window holds several sessions in one tab view

- **Status**: Accepted
- **Date**: 2026-10-28

## Context

Under [0012](0012-window-per-session.md) a window holds at most one connection session. Working on two databases means two windows, and the saved connections and their groups show only on the picker, which goes once a window connects. Users who come from clients that list every connection in one tree, with tabs of several connections side by side, ask for that flow.

0012 rejected a window that swaps one session in place, because every part that read the session had to be reset at each switch and a late reply could land in the next session. It also rejected one session service shared by every window.

## Decision

A `SessionWindow` holds a list of open sessions, each under its own `SessionClaim`, and a list of connects in progress, each with its own cancel token. The page it shows follows from those two lists: the `WorkspaceShell` while any session is open, else the first connect's progress, else the last failure, else the picker. Every connect, from the picker, the sidebar, the connect dialog, a file, a restore or MCP, takes the same path.

The shell is what a window has once: the header bars, the sidebar, the one `AdwTabView` every session's tabs share, the assistant's column and the toasts. Each session keeps its own `Workspace`, which holds what it held before, and a tab never changes session. The sidebar is a tree of the saved connections in their groups, with the schemas and tables of each open session under its connection.

## Rationale

- What 0012 protects still holds one level down. A workspace never changes session, so it has nothing to reset, and its teardown order is the same. Tabs already took their session when they were built.
- Sessions are not shared across windows. The registry still keeps a key in one window, and a connection open elsewhere brings that window and that session forward.
- The session of the tab in front speaks for the window. The shell's `front` property follows the tab view's selection, and the header bars, the banners, the assistant's pane and the window's actions read it through bindings, so a change of tab never enters a workspace that is handling input.
- A failure while other sessions are open is an event in this window, so it is a toast with a Details button rather than a page or a new window. The GNOME HIG: "Never pop up a dialog window unexpectedly."
- A closed connection is a leaf in the tree, and activating it connects, as a GNOME Files sidebar row mounts a volume. A connection gets its schemas once its session joins, so neither a drag hovering over a row nor an expander starts a network connect.
- Each schema's tables are a lazy list of their own, filled from one search worked out off the GTK thread, so a catalog of 50,000 tables makes objects only for the rows on screen.

## Consequences

- This supersedes 0012 for what a window holds. The application, the subclasses and the input queues it decided stay.
- A disconnect asks only that session's prompts and closes its tabs. When the last session goes, a connect still running shows on the connecting page and joins when it lands; with none, the window returns to the picker. The window's close asks one Save Changes? across every session, and Cancel keeps them all.
- libadwaita 1.9 has no tab groups, so any `AdwTabBar` in the process accepts a dropped tab. The shell sends a tab dropped from another window back to its own, and a tab dropped outside every window stays in its window.
- Each tab names its connection, as "orders (prod)", while another connection has a tab in the same bar.
- The restore record groups the keys by window, so a restore opens each window with the sessions it held.

## Alternatives considered

**A window per session with a strip to switch between them.** Keeps 0012 whole, but the tabs of two connections are never side by side.

**A tab bar per session in one window.** Smaller, but switching connection hides the other connection's tabs.

**A failed connect beside the sessions on a failed page in a window of its own.** Keeps the page's remedies, but a window opens seconds after the user moved on. The remedies are dialogs over this window already.
