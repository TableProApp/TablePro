# State management

The `app` crate's application, windows, workspace and tabs are gtk-rs subclasses ([decisions/0012-window-per-session.md](decisions/0012-window-per-session.md)). A few views are still [Relm4](https://relm4.org) components ([decisions/0003-relm4-architecture.md](decisions/0003-relm4-architecture.md)): `WelcomeView`, the `ConnectionRow` and `SidebarRow` factories, and the history, saved-queries and CSV import dialogs. New views are subclasses. This page covers where state lives, the rules every view follows, and the patterns for each kind.

## Where state lives

| State | Owner | Lives as long as |
|---|---|---|
| Driver registry, connector, deadlines, settings, storage, `Tasks`, `SessionRegistry`, query history, the open-sessions record | `AppServices`, built by `run()` and handed to every window | the process |
| The claim on a session's key | the window's `SessionPage` | the page |
| The connection | `Session`, shared by the window's page and its workspace | the page, until the teardown closes it |
| Schemas, objects and columns | the session's `SchemaCatalog` | the session |
| Tabs, pending edits, running saves | the `Workspace`: `ChangeTrackerRegistry`, `StructureTrackerRegistry`, `WorkspaceHandle` with its `SaveLedger` | the workspace |
| Running exports | the workspace's `ExportLedger` | the workspace |
| A tab's rows, filter and requests | the tab's model, in its `imp` struct | the tab |

Windows share nothing but `AppServices`. CI fails on a `thread_local!` under `crates/app/src/services`, since a registry shared that way would show one window's unsaved edits in every other window.

## Rules for every view

**Background work goes through `Tasks`.** Use `crate::runtime::spawn_and_deliver` to run work on the app runtime and get its result on the GTK thread, and `spawn_held` for work the user expects to finish, such as a save. `crates/app/clippy.toml` bans `tokio::spawn`, `Handle::current`, `relm4::spawn` and their siblings, so nothing reaches for whichever runtime happens to be ambient.

**Input goes through `DeliverInput::deliver`.** It works on an input queue's sender, a `relm4::Sender`, a `ComponentSender` and a `FactorySender`. A message to a view that has shut down is dropped and logged at debug under the `component` target, so a read or a save that comes back after its window closed changes nothing. `ComponentSender::input` and `FactorySender::input` are banned: relm4 0.11 calls `expect` on a closed channel, which would take every window down. Use `try_deliver` when the caller must act on a dropped message, as `QuitSequence` does when a window is already gone.

**A watch loop is a `WatchForwarder`.** The session publishes its health (`Session::health`), its link generation (`link_changes`) and each scope's objects (`subscribe_objects`) on `tokio::sync::watch` channels. A view keeps a `WatchForwarder` in a field: it delivers the current value, then every change, on the GTK thread, and stops when the field drops. A value published after the view went away is never delivered.

**A view holds the session, never a connection.** Every read and write goes through the session (`Session::run`, `run_cancellable`, the catalog reads), which leases the current link through its `OperationRunner` and carries the deadline to the driver. A view asks the session for the dialect (`current_dialect`) and asks again when the link changes, since a reconnect can reach another server version. A save plans with the dialect of the connection that runs it.

**One request of each kind is current.** A browse or structure tab keeps a `RequestSequencer` keyed by request kind. `issue` returns a `RequestTicket` with a stamp and a cancel token, and stops the request of that kind still running, so the server drops the statement. `accept` takes only the reply to the current request; a reply to a replaced one is dropped. Dropping the sequencer stops every request, which is how closing a tab stops its reads.

**A failed read is asked again on the next link.** `FailedRequests` holds the kinds whose last accepted reply failed. When `link_changes` reports a newer `LinkGeneration`, the tab asks those again on the new connection; a reply that failed after the link had already moved is asked again at once. A tab whose reads all landed keeps its rows.

**The catalog belongs to the session.** `SchemaCatalog` (`crates/session/src/session/schema_catalog.rs`) holds the schemas, each scope's objects and each table's columns. Views read through `Session::schemas`, `objects` and `columns`, or `refresh_objects` and `refresh_columns` to fetch again. Callers that ask for the same thing at once share one fetch, a fetch runs as its own task so a view that closes does not stop it, and a failed refresh keeps the list it had. A schema change calls `invalidate_table`, which marks the table stale and keeps its data until the next fetch lands.

**Saves go through the workspace.** `WorkspaceHandle` starts, stops and settles every save. Its `SaveLedger` records each running save with its tab, its kind, a cancel token and a process hold, and refuses a second save of the same kind for the same tab. Stop Saving, or a close that chose to stop, cancels the token, which reaches the driver through `run_cancellable`; the save settles when the driver answers.

**Closing asks through the window's prompts.** `CloseGuards` runs one `CloseGuard` at a time per window, so a tab's close and the window's never ask about the same tab at once. A guard reads the workspace again after every answer and every settled save: it offers to save, waits for or stops running saves, asks about a save whose outcome is unknown, and confirms open transactions. Before any of that, a close of the whole window asks each `CloseBlocker` the workspace registered, such as its `ExportLedger`, and either keeps the window or stops that work and waits for it. A disconnect asks the same prompts before the teardown.

## Windows and the workspace

`SessionWindow` and `Workspace` each own an input queue from `runtime::input_queue`:

- Actions, signal handlers and background work send it a message, and `pump_inputs` hands the messages to the widget one at a time on the GTK thread, never inside the signal or action that sent one.
- Shutdown aborts the pump, which closes the queue. A queued message that owns something, such as a connection that finished connecting, goes to the pump's leftover handler (`pump_inputs_with_leftovers`) and is closed rather than dropped.
- Window actions go on the window's own action map with `add_action_entries`, which GTK exports as `win`; CI fails on a group inserted as `win`. The workspace removes the actions it added when it shuts down.
- The workspace reports to the window through signals (`title-changed`, `dirty-changed`, `saves-in-flight-changed`), and the window turns each into one of its own inputs.

A background read follows this shape, trimmed from `SessionWindow::on_restore`, which looks up the saved connection `id` names:

```rust
let (Some(state), Some(input)) = (self.state(), self.input()) else {
    return;
};
let store = state.services.storage.connections().clone();
let reading = state.services.tasks.spawn_blocking_task(move || store.load_blocking());
glib::spawn_future_local(async move {
    if let Ok(Ok(connections)) = reading.await {
        let saved = connections.iter().find(|saved| saved.id == id).cloned().map(Box::new);
        input.deliver(SessionWindowInput::RestoreSaved { id, saved });
    }
});
```

The closure holds only the sender, so a window that closed before the read ends is not kept alive, and the answer is dropped.

## Tabs

A browse or structure tab is a subclass whose model sits in its `imp` struct. `send` hands the model one input and handles it at once; an input a widget signal sets off while another is being handled waits in the tab's queue until that one finishes. The model's update returns effects: more inputs for the queue, and outputs the tab emits as signals. The workspace connects those signals, tags them with the tab's id and queues them as `WorkspaceInput`, so the tabs never call each other.

## Relm4 components

The components that remain follow these conventions until a rewrite turns them into subclasses:

- Input reaches them through `deliver`, and their output reaches the subclass that hosts them through `connect_receiver` or `runtime::relm4_bridge`, which put it on that subclass's queue.
- Their commands (`sender.command`, `oneshot_command`) run on Relm4's own runtime, not on `Tasks`. The history and saved-queries dialogs still load that way; new work goes through `spawn_and_deliver`.
- They present their dialogs on the window they belong to. `ComponentBuilder::transient_for` is banned, because Relm4 applies it only from `relm4::RelmApp`, which this app does not use.

## Naming

- `<Thing>Input`: every message a view handles, as an enum (`SessionWindowInput`, `WorkspaceInput`, `BrowseTabInput`).
- `<Thing>Output`: only the messages a parent should react to.
- `<Thing>Cmd`: a Relm4 command's result.
- `<Thing>Init`: what the parent hands a view when it builds it (`SessionWindowInit`, `WorkspaceInit`).

## Alert dialogs

- `AdwAlertDialog` closes itself before it emits `response`. A response handler that calls `close()` again finds the dialog gone, and libadwaita logs a critical when animations are off.
- That close emits `closed` before the `response` the click chose. A `closed` handler that answers at once turns every click into the close response. `workspace::respond` defers its close response to an idle callback, so the click's response comes first.
- To wait for an answer, use `workspace::respond`, which also answers when the dialog goes without a response. `choose_future` is not used: its callback aborts the process in that case.

## Anti-patterns to flag in review

- `tokio::spawn`, `relm4::spawn` or `Handle::current` in app code. Use `Tasks`.
- `ComponentSender::input` or `FactorySender::input`. Use `deliver`.
- A hand-written loop over a watch channel. Use `WatchForwarder`.
- A view that keeps a `Connection`, or a dialect past a link change.
- State in a `thread_local!` or a static. It belongs to the workspace or to `AppServices`.
- A `glib::clone!` that captures a view strongly in a callback the view itself holds. Capture its input sender or a weak reference.
- Blocking work on the GTK thread: `std::fs`, a `_blocking` call outside `spawn_blocking_task`, or `MainContext::block_on`.

## Testing

[testing.md](testing.md#app--ui-tests) covers widget tests, the test windows and the application tests.
