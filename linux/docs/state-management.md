# State management with Relm4

The `app` crate's windows and workspace are gtk-rs subclasses ([decisions/0012-window-per-session.md](decisions/0012-window-per-session.md)); its other views are still [Relm4](https://relm4.org) components ([decisions/0003-relm4-architecture.md](decisions/0003-relm4-architecture.md)). This file describes the patterns we follow inside the codebase. For the Relm4 components, read the official Relm4 book first; this document only covers the conventions specific to TablePro Linux.

## Windows and the workspace

`SessionWindow` and `Workspace` are subclasses with a CompositeTemplate `.ui` file in the GResource, and each owns an input queue from `runtime::input_queue`:

- Actions, signal handlers and background work send it a message, and `pump_inputs` hands the messages to the widget one at a time on the GTK thread, never inside the signal or action that sent one.
- Background work runs on the app's `Tasks` and answers through the queue with `DeliverInput::deliver`, which drops the answer once the widget has shut down.
- Shutdown aborts the pump, which closes the queue. A message still queued that owns something, such as a connection that finished connecting, goes to the pump's leftover handler (`pump_inputs_with_leftovers`) and is closed rather than dropped.
- Window actions go on the window's own action map with `add_action_entries`; the workspace removes the ones it added when it shuts down.
- Work the user expects to finish, such as a save, runs through `runtime::spawn_held`, which holds the process until it ends.

The rest of this page applies to the Relm4 components.

## When to use which component flavour

| Flavour | Use when |
|---|---|
| `Component` | Synchronous init, no async work in `update`. Default choice. |
| `AsyncComponent` | Loading data on init or in update is the core of the component. Connection list, table content viewer. |
| `SimpleComponent` | A leaf widget with no `Output` to its parent. Avoid; very few cases. |
| `Factory` (`FactoryComponent`) | A homogeneous list of children driven by a model. Connection sidebar entries, tab strip items. |
| `Worker` | Background unit that does not own widgets. Use for the driver registry interaction; receives requests, returns results. |

If you find yourself reaching for a static `Mutex<AppState>`, you are not using the framework. Stop and re-read the model.

## Component skeleton

```rust
use relm4::{Component, ComponentParts, ComponentSender};

pub struct ConnectionListModel {
    connections: Vec<SavedConnection>,
    selected: Option<ConnectionId>,
}

#[derive(Debug)]
pub enum ConnectionListInput {
    Select(ConnectionId),
    Connect(ConnectionId),
    Delete(ConnectionId),
    Reload,
}

#[derive(Debug)]
pub enum ConnectionListOutput {
    OpenConnection(SavedConnection),
}

#[derive(Debug)]
pub enum ConnectionListCmd {
    Reloaded(Vec<SavedConnection>),
}

impl Component for ConnectionListModel {
    type Init = ();
    type Input = ConnectionListInput;
    type Output = ConnectionListOutput;
    type CommandOutput = ConnectionListCmd;
    type Root = gtk::Box;
    type Widgets = ConnectionListWidgets;

    fn init(_: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        // Build widgets, attach handlers, return ComponentParts
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, _: &Self::Root) {
        match msg {
            ConnectionListInput::Select(id) => self.selected = Some(id),
            ConnectionListInput::Reload => sender.command(|out, shutdown| {
                shutdown.register(async move {
                    let conns = storage::load_connections().await.unwrap_or_default();
                    out.send(ConnectionListCmd::Reloaded(conns)).ok();
                }).drop_on_shutdown()
            }),
            // ...
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, _: ComponentSender<Self>, _: &Self::Root) {
        match msg {
            ConnectionListCmd::Reloaded(conns) => self.connections = conns,
        }
    }
}
```

Naming:

- Model: `<Thing>Model`. Holds private state.
- Input: `<Thing>Input`, an enum. Every UI interaction is a message.
- Output: `<Thing>Output`, an enum. Only the messages a parent should react to.
- Command output: `<Thing>Cmd`, an enum. Async work finishes by sending one of these back.

## Async work via commands

Components do not call `tokio::spawn` directly. They issue commands:

```rust
sender.command(|out, shutdown| {
    shutdown
        .register(async move {
            let result = some_async_work().await;
            out.send(MyCmd::Done(result)).ok();
        })
        .drop_on_shutdown()
})
```

The command runs on the runtime owned by `app::runtime`. It is automatically cancelled when the component is destroyed. **Always use `drop_on_shutdown`** unless the work is critical to complete (rare; saving user data is the main case).

## Talking to drivers

Driver interaction is centralised in `app::services::DatabaseService`. Components never call `core::DriverRegistry` directly. They send a request to the service worker and receive a typed reply.

```rust
let req = DatabaseRequest::FetchRows {
    connection_id,
    table: "users".into(),
    offset: 0,
    limit: 1000,
};
db_service.send(req);
// In update_cmd:
DatabaseReply::Rows { rows, .. } => { /* update model */ }
```

Why centralise: connection lifecycles, retries, health pings, cancellation, logging are concerns the UI must not see.

## State that does not belong in a component

Some state is genuinely global: open connections, the driver registry, app settings. We model these as `Worker` components or as `Arc<RwLock<T>>` owned by `app::main` and passed to component `init` payloads. Never reach for global statics other than the tokio runtime handle and the application identifier.

## Anti-patterns to flag in review

- `gtk::glib::clone!` capturing `&mut` references to model fields. Use `ComponentSender` and route via `Input`.
- Async work spawned with raw `tokio::spawn` from inside a component. Use `sender.command`.
- Components reading from a `Mutex<AppState>`. Pass state in via `Init` or via parent → child `Input`.
- A `Component` doing async work in its `init`. Promote to `AsyncComponent`.
- One enormous `Input` enum with 30 variants. Split the component.

## Testing components

Relm4 ships test helpers but they require a running GTK main loop, which is awkward in CI. Our policy:

- Test pure logic by extracting it into plain Rust functions or a separate `services` module. Test those.
- Do not write component-level tests until we hit a bug that they would have caught.
- Prefer integration tests at the driver layer and unit tests at the model layer.
