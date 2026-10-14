# 0012: One window per connection session, built from gtk-rs subclasses

- **Status**: Accepted
- **Date**: 2026-10-14

## Context

Each window used to be one Relm4 `App` component that connected, disconnected and switched connections in place. Everything that read the session (tabs, the sidebar, watches, replies still on their way) had to be reset by hand at every switch, and a reply from the old session could land in the new one.

The 2026-09-14 dependency review found Relm4 used by none of the 31 Rust apps in GNOME Core and Circle, and found the plan wrapping its runtime and spawn functions and banning parts of its API to work around it.

## Decision

A window is a `SessionWindow` that holds at most one connection session: it shows the picker, the connect in progress, the failed connect, then the session's `Workspace`, and a disconnect tears the workspace down and returns to the picker. `SessionWindow` and `Workspace` are gtk-rs subclasses with CompositeTemplate `.ui` files in the GResource, not Relm4 components. Their actions go on the window's own action map through `add_action_entries`, and their input goes through `runtime::input_queue`, handled one message at a time on the GTK thread.

## Rationale

- A workspace that never changes session has nothing to reset. Its teardown writes what it shows, closes its input queue and drops it before the session closes, so a late reply has nowhere to land.
- Every connect claims the session's key in the `SessionRegistry` first, so a second window asking for the same database brings the first forward instead of connecting.
- Subclasses with templates are what GNOME's Rust apps and the gtk-rs book use. The input queue keeps what Relm4 gave: one message at a time, never handled inside the signal or action that sent it, and dropped once the widget is gone.

## Consequences

- This supersedes [0003](0003-relm4-architecture.md) for windows and the workspace. The Relm4 components that remain follow 0003 until a rewrite turns them into subclasses, so two patterns coexist until then.
- A message sent to a window or workspace after it shut down is dropped. One that owns something, such as a connection that finished connecting, is closed instead.
- Ctrl+W and the close prompts belong to the window, so they work on every page, not only while a session is open.

## Alternatives considered

**Keep one `App` per window that swaps sessions.** The source of the cross-session replies and the per-switch resets.

**A Relm4 `SessionWindow` component.** Keeps the wrappers the dependency review removes.

**One process-wide session service shared by every window.** Ties every window to one session's lifetime and brings back the reset problem one level up.
