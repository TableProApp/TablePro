# State management

The `app` crate's application, windows, workspace and tabs are gtk-rs subclasses ([decisions/0012-window-per-session.md](decisions/0012-window-per-session.md)). A few views are still [Relm4](https://relm4.org) components ([decisions/0003-relm4-architecture.md](decisions/0003-relm4-architecture.md)): the saved-queries and CSV import dialogs. New views are subclasses. This page covers where state lives, the rules every view follows, and the patterns for each kind.

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
| An editor tab's own connection | the tab's `EditorSessionSlot` | the tab, or until that connection is lost or the window's session is replaced |
| What the last run returned | the editor tab's `RunLog`, shown by its `ResultsPane` | the next run |
| The history list, its search and the pages read | the `HistoryDialog` and its `HistoryPaging` | the dialog |

Windows share nothing but `AppServices`. CI fails on a `thread_local!` under `crates/app/src/services`, since a registry shared that way would show one window's unsaved edits in every other window.

## Rules for every view

**Background work goes through `Tasks`.** Use `crate::runtime::spawn_and_deliver` to run work on the app runtime and get its result on the GTK thread, and `spawn_held` for work that has to finish even if its window goes, such as saving a named query or importing a connection list. A table or structure save goes through `WorkspaceHandle::save`, whose `SaveLedger` holds the process. `crates/app/clippy.toml` bans `tokio::spawn`, `Handle::current`, `relm4::spawn` and their siblings, so nothing reaches for whichever runtime happens to be ambient.

**Input goes through `DeliverInput::deliver`.** It works on an input queue's sender, a `relm4::Sender`, a `ComponentSender` and a `FactorySender`. A message to a view that has shut down is dropped and logged at debug under the `component` target, so a read or a save that comes back after its window closed changes nothing. `ComponentSender::input` and `FactorySender::input` are banned: relm4 0.11 calls `expect` on a closed channel, which would take every window down. Use `try_deliver` when the caller must act on a dropped message, as `QuitSequence` does when a window is already gone.

**A watch loop is a `WatchForwarder`.** The session publishes its health (`Session::health`), its link generation (`link_changes`) and each scope's objects (`subscribe_objects`) on `tokio::sync::watch` channels. A view keeps a `WatchForwarder` in a field: it delivers the current value, then every change, on the GTK thread, and stops when the field drops. A value published after the view went away is never delivered.

**A view holds the session, never a connection.** Every read and write goes through the session (`Session::run`, `run_cancellable`, the catalog reads), which leases the current link through its `OperationRunner` and carries the deadline to the driver. A view asks the session for the dialect (`current_dialect`) and asks again when the link changes, since a reconnect can reach another server version. A save plans with the dialect of the connection that runs it.

**One request of each kind is current.** A browse or structure tab keeps a `RequestSequencer` keyed by request kind. `issue` returns a `RequestTicket` with a stamp and a cancel token, and stops the request of that kind still running, so the server drops the statement. `accept` takes only the reply to the current request; a reply to a replaced one is dropped. Dropping the sequencer stops every request, which is how closing a tab stops its reads.

**A failed read is asked again on the next link.** `FailedRequests` holds the kinds whose last accepted reply failed. When `link_changes` reports a newer `LinkGeneration`, the tab asks those again on the new connection; a reply that failed after the link had already moved is asked again at once. A tab whose reads all landed keeps its rows. A browse tab's row count is not asked again: it can run for its whole deadline, so it runs only when the estimate or the user asks.

**Content stays through a failed read.** A browse or structure tab tracks its read with `ContentLoad`. The spinner shows only until the first read lands; a read of the content on screen keeps it there and spins the tab's page in the tab bar, and a failure then leaves it under a `StaleBanner` with Retry. The error page, with Try Again, is for a tab with nothing to show, or whose failed read asked for other rows than the ones on screen.

**The catalog belongs to the session.** `SchemaCatalog` (`crates/session/src/session/schema_catalog.rs`) holds the schemas, each scope's objects and each table's columns. Views read through `Session::schemas`, `objects` and `columns`, or `refresh_objects` and `refresh_columns` to fetch again. Callers that ask for the same thing at once share one fetch, a fetch runs as its own task so a view that closes does not stop it, and a failed refresh keeps the list it had. A schema change calls `invalidate_table`, which marks the table stale and keeps its data until the next fetch lands. The sidebar's Refresh, and an editor run that sent DDL or a commit (`catalog_change::changes_catalog`), cannot name the tables they touched: they call `invalidate_columns`, which does the same for every table, and read the object lists again. A failed read leaves the sidebar's list under a banner with Retry until a read lands.

**Saves go through the workspace.** `WorkspaceHandle` starts, stops and settles every save. Its `SaveLedger` records each running save with its tab, its kind, a cancel token and a process hold, and refuses a second save of the same kind for the same tab. Stop Saving, or a close that chose to stop, cancels the token, which reaches the driver through `run_cancellable`; the save settles when the driver answers.

**A structure save is reviewed before it starts.** `WorkspaceHandle::save` is the one route for a tab's Save and Ctrl+S and for a close that chose Save, so the review is never skipped. For a structure tab it plans the draft with the session's `DdlDialect` into a `ChangeReview` before it takes anything from the tracker or opens a `SaveLedger` entry:

- The review dialog asks first when the plan loses something (a dropped column, index or foreign key, a type change, a table rebuild), or when the engine applies DDL statement by statement (`EngineProfile`, from the driver's `ddl_writes`) and the plan has more than one statement. Cancel is the default response.
- After Apply the draft is planned again, and a plan that changed while the dialog was open is refused with `BuildDdlError::NotAsReviewed`. The save itself runs only a plan that `ChangeReview::matches`, so a connection replaced in the meantime never runs statements the user did not see.
- A tab has one review at a time. A second save while it is open gets `SaveRejection::InReview`.
- Cancel returns `SaveRejection::ReviewDeclined`, which shows no alert. `CloseGuard` takes it as Keep Open and starts none of the saves after it.

**Closing asks through the window's prompts.** `CloseGuards` runs one `CloseGuard` at a time per window, so a tab's close and the window's never ask about the same tab at once. A guard reads the workspace again after every answer and every settled save: it offers to save, waits for or stops running saves, asks about a save whose outcome is unknown, and confirms open transactions. Before any of that, a close of the whole window asks each `CloseBlocker` the workspace registered, such as its `ExportLedger`, and either keeps the window or stops that work and waits for it. A disconnect asks the same prompts before the teardown.

## Windows and the workspace

`SessionWindow` and `Workspace` each own an input queue from `runtime::input_queue`:

- Actions, signal handlers and background work send it a message, and `pump_inputs` hands the messages to the widget one at a time on the GTK thread, never inside the signal or action that sent one.
- Shutdown aborts the pump, which closes the queue. A queued message that owns something, such as a connection that finished connecting, goes to the pump's leftover handler (`pump_inputs_with_leftovers`) and is closed rather than dropped.
- Window actions go on the window's own action map with `add_action_entries`, which GTK exports as `win`; CI fails on a group inserted as `win`. The workspace removes the actions it added when it shuts down.
- The workspace reports to the window through signals (`title-changed`, `dirty-changed`, `saves-in-flight-changed`, `work-completed`, `tabs-changed`), and the window turns each into one of its own inputs.

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

## The SQL editor

`SqlEditor` (`crates/app/src/ui/editor/`) runs SQL on a connection of its own and lists what each statement returned.

### The tab's connection

Each editor tab runs on an `EditorSession`, which keeps a transaction, temporary tables and session settings between runs. The tab's `EditorSessionSlot` holds it, shared with the run on the runtime:

- **Empty** until the first run, which opens one from the window's session with `Session::open_editor_session`.
- **Open** while it serves the window session it was opened from. One that is `Lost`, or that belongs to a session the window has since replaced, is closed before the next run opens another. An editor session is never reopened behind the user's back: the failed run's line says the next run opens a new one, since the transaction went with the old one.
- **Closed** once the tab goes (`EditorSessionSlot::close`). A session that finishes opening after that is handed back and closed, never kept.

After a run that left its session `Lost`, the runner lets it go and asks the window's session to probe its own link, which may have gone too. A teardown takes every tab's session (`SqlEditor::take_editor_session`) and closes them together under one hold.

### What a run sends

1. **Scope.** Run sends the selection when there is one and the whole buffer otherwise (`run_scope::for_run`). Run at Cursor selects the statement under the cursor and sends that. `ScopedText` keeps where the text starts in the buffer, in characters, so a server's error position becomes a buffer position.
2. **Plan.** `plan_batches` reads the text with `ScriptPlan` and the grammar of the window session's dialect, or PostgreSQL's when there is none. Each `RunBatch` is one statement on PostgreSQL, MySQL, SQLite and ClickHouse, and one `GO` batch on SQL Server, which `GO <count>` repeats. psql, mysql and sqlite3 send a script the same way: no multi-statement text reaches the server, so an implicit transaction never rolls back statements that already reported success. On SQL Server the unit is the `GO` batch, as in sqlcmd: a batch reaches the server whole, whatever `;` it holds. The plan is built again at every run, never kept.
3. **Warnings.** A string, quoted name, comment or dollar quote that never closes adds a warning line naming its line. The text is still sent, so the server has the last word.
4. **Runs.** `run_batches` sends each batch as one `EditorSession::run`, with the statement timeout from Preferences, the editor's row limit and a child of the run's cancel token. A run that gets `EditorSessionBusy`, because the last one is still settling, is shown as failed and not sent again.
5. **Stopping.** A failed statement stops the script, since the ones after it were written assuming it worked. SQL Server batches run on their own, as in sqlcmd, so a failed `GO` batch goes on to the next (`BatchErrorPolicy::ContinueNextBatch`). A cancel, a timeout or a session error stops the script on every engine. Each batch never sent gets a Not Run line.

The editor plans with the grammar's defaults (`LexicalSettings::default_for`): backslash escapes on for MySQL and ClickHouse, off for the rest. It does not read the session's own settings. The PostgreSQL driver plans what each run sends again with the session's `standard_conforming_strings`, which it reads from the server's parameter status, and plans the rest of that text again after a statement that changes it.

### The results list

Events cross to the GTK thread through a channel. `BatchCollector` turns one batch's `ResultEvent`s into lines on the runtime, so only finished lines cross, and `RunLog` keeps the run's lines in order: a result set, a command with the rows it changed, a notice, a failure with the server's error position when it gives one, a warning, a stop, a timeout, and a Not Run line per batch never sent.

`ResultsPane` shows them as a list in an `AdwOverlaySplitView` beside the page of the selected line:

- One line needs no list. The list and its toggle appear with the second line, and the list opens by itself while the pane is wide. Below 560sp it folds over the result, and opening it is left to the toggle (`sidebar_policy`).
- A page is built when its line is first shown, and the 8 shown last keep theirs, so a script of thousands of statements builds a handful.
- When the run ends, the first failure or timeout is selected, or else the first line. A failure's page offers Go to Error when the server named a position.
- A result set's page is a read-only grid of the rows the run kept, under a `ResultLimitBanner` when the row limit cut it short.

A finished run goes to `HistoryService::record` with the text that was run, `DELIMITER` and `GO` lines included, judged by the dialect of the session that ran it, not the window's current one ([storage.md](storage.md#what-goes-into-the-history)).

### The tab's file

Open SQL File (Ctrl+O) and Save As (Ctrl+Shift+S) bind the tab to a `.sql` file, through the file chooser portal; Save (Ctrl+S) writes to it, or asks for one. The tab is named after the file, and the buffer's own modified flag says whether its text differs from the file's, so Undo back to the saved text clears it. The tab's record keeps the file's URI and that flag (`EditorFileRecord`), and its draft keeps the text, so a restore brings back both.

Closing the tab asks about unsaved file changes through the same Save Changes prompt as row and structure edits (`DirtyKind::UnsavedFile`), and its Save writes the file. Closing the window does not ask: the draft keeps the text for the next session.

### Open transactions

Every `RunSummary` carries the session's `TransactionState`, and the last one a run reported decides whether closing the tab would lose work (`transaction_dirty`):

- `InTransaction` and `Failed` count, and the line above the results says so.
- `Unknown` counts once something ran, because the engine cannot say what that left.
- A lost session holds nothing any more, so it never counts.

The tab emits `transaction-changed` when that flips, and the workspace reads `WorkspaceHandle::dirty_tabs` again. Through `TabDirectory::tabs` it lists the tab as `DirtyKind::OpenTransaction` when the tab has nothing else pending, so the page shows the unsaved icon and the close prompts ask about it. A close asks once: the tabs the user agreed to lose are not asked about again in that close.

## The query history dialog

`HistoryDialog` reads the history a page of 100 at a time off the GTK thread, by the keyset [storage.md](storage.md#searching-the-history) describes.

- `HistoryPaging` numbers each refresh. A page that lands for an older search is dropped, a new search drops the old cursor, and one next-page read runs at a time.
- A refresh keeps the rows on screen until its first page lands, so typing never blanks the list, and a refresh that fails keeps them.
- Pinning moves the row to where the history now lists it without reading again. A row that now sorts past the pages read comes back with its page.
- Delete happens at once and offers Undo ([storage.md](storage.md#deleting-and-restoring)).

## Relm4 components

The components that remain follow these conventions until a rewrite turns them into subclasses:

- Input reaches them through `deliver`. Their output reaches the subclass that hosts them through `connect_receiver`, whose closure delivers it to that subclass's queue.
- Their commands (`sender.command`, `oneshot_command`) run on Relm4's own runtime, not on `Tasks`. The saved-queries dialog still loads that way; new work goes through `spawn_and_deliver`.
- They present their dialogs on the window they belong to. `ComponentBuilder::transient_for` is banned, because Relm4 applies it only from `relm4::RelmApp`, which this app does not use.

## Naming

- `<Thing>Input`: every message a view handles, as an enum (`SessionWindowInput`, `WorkspaceInput`, `BrowseTabInput`).
- A view with many inputs groups them by the state each one changes, one enum per group (`BrowseTabInput::Paging(PagingInput)`, `StructureTabInput::Save(SaveInput)`), and handles each group in its own `*_handlers` module. Senders pass the group's enum; `send` takes anything that converts into the view's input.
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
- A whole script handed to `EditorSession::run`. Plan it and send one statement, or one `GO` batch, per run.
- A structure save that calls `SaveLedger::begin` itself. Go through `WorkspaceHandle::save`, which reviews first.
- State in a `thread_local!` or a static. It belongs to the workspace or to `AppServices`.
- A `glib::clone!` that captures a view strongly in a callback the view itself holds. Capture its input sender or a weak reference.
- Blocking work on the GTK thread: `std::fs`, a `_blocking` call outside `spawn_blocking_task`, or `MainContext::block_on`.

## Testing

[testing.md](testing.md#app--ui-tests) covers widget tests, the test windows and the application tests.
