# State management with Relm4

The `app` crate uses [Relm4](https://relm4.org) on top of gtk4-rs. The choice is recorded in [decisions/0003-relm4-architecture.md](decisions/0003-relm4-architecture.md). This file describes the patterns we follow inside the codebase. Read the official Relm4 book first; this document only covers the conventions specific to TablePro Linux.

## When to use which component flavour

| Flavour | Use when |
|---|---|
| `Component` | Synchronous init, no async work in `update`. Default choice. |
| `AsyncComponent` | Loading data on init or in update is the core of the component. Connection list, table content viewer. |
| `SimpleComponent` | A leaf widget with no `Output` to its parent. Avoid; very few cases. |
| `Factory` (`FactoryComponent`) | A homogeneous list of children driven by a model. Connection sidebar entries, tab strip items. |
| `Worker` | Background unit that does not own widgets. Unused today: services are `Arc`-shared structs and async work runs through component commands. |

If you find yourself adding a global singleton for application state, you are not using the framework. Stop and re-read the model.

## Component structure

Use [the existing editor component](../crates/app/src/ui/editor/mod.rs) for the
message/command shape. Commands return `Result` outcomes to the update loop;
a failed storage read must remain visible rather than becoming an empty model.

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

The command runs on the Tokio runtime Relm4 owns, and is cancelled when the component is destroyed. **Always use `drop_on_shutdown`** unless the work is critical to complete (rare; saving user data is the main case).

## Talking to drivers

Driver interaction is centralised in `app::services::database_service::DatabaseService`. Components never call `core::DriverRegistry` directly.

The service is not a Relm4 `Worker` and has no request/reply enums. It is a plain struct the application owns as an `Arc` and passes explicitly into the windows and dialogs that need it. It owns the connection map, health, the reconnect monitor, the audit runtime and the policy configuration, and it hands out a guarded connection handle:

```rust
let Some(conn) = self.window_connection() else {
    return;
};
sender.command(move |_, shutdown| {
    shutdown
        .register(async move {
            let control = operation_control::bounded(timeout_secs);
            let result = conn
                .fetch_rows_controlled(schema.as_deref(), &table, offset, limit, &control)
                .await;
            // route the outcome back through an Input message
        })
        .drop_on_shutdown()
});
```

`DatabaseService::get` and `handle` wrap the live connection in a `PolicyGuard` before returning it, so a component cannot reach a raw driver connection even by accident. Classification, approval, masking, audit and driver-panic containment all happen inside that handle.

Why centralise: connection lifecycles, retries, health pings, cancellation and policy are concerns the interface must not reimplement.

## State that does not belong in a component

Some state outlives any single component: open connections, user preferences, query history, the workspace cache and the MCP bridge. The application owns these as `Arc`s and passes them explicitly into each window, tab and dialog that needs them. They were global singletons until the 0.2 sprint, and that is exactly what the `Arc` handles replaced.

Per-tab editing state is the deliberate exception. `change_tracker`, `structure_tracker` and `window_registry` keep a `thread_local!` registry keyed by tab or window id. That is sound because each is confined to the GTK main thread by the Relm4 contract, which is also why they use `RefCell` rather than `Mutex`. Threading a registry handle through every grid cell binding would cost more in the hot `connect_bind` path than it buys. Tests construct a fresh registry rather than sharing the thread-local one.

## Two persistence primitives, deliberately not one

`services::state_file::StateFile<T>` and `services::workspace_state::WorkspaceStore` both own a background writer thread, which makes them look like duplicates. They are not, and merging them would lose a guarantee.

| | `StateFile<T>` | `WorkspaceStore` |
|---|---|---|
| Unit of write | the whole `T` | per-connection entries |
| Write shape | serialize the owned value | reload from disk, merge the pending entries, save |
| Concurrency | one owner, revision coalescing | file lock across processes and windows, sequence-ordered |
| On failure | settles waiters with a write error | restores the pending entries for the next attempt |
| Errors | `String` | typed `WorkspaceFlushError` |

The read-modify-write under a file lock is the point: two windows save different connections at the same time, and a whole-value write would drop whichever landed first. `StateFile` is correct for a single owned document such as preferences; `WorkspaceStore` is correct for a map many windows write into. Use `StateFile` for new whole-document state, and do not port `WorkspaceStore` onto it.

## Anti-patterns to flag in review

- `gtk::glib::clone!` capturing `&mut` references to model fields. Use `ComponentSender` and route via `Input`.
- Async work spawned with raw `tokio::spawn` from inside a component. Use `sender.command`.
- A new global singleton for state the application could own and pass in. Pass it via `Init` or parent to child `Input`. The main-thread `thread_local!` tab registries are the documented exception, not a precedent to extend.
- A `Component` doing async work in its `init`. Promote to `AsyncComponent`.
- One enormous `Input` enum with 30 variants. Split the component.

## Testing components

Relm4 ships test helpers but they require a running GTK main loop, which is awkward in CI. Our policy:

- Test pure logic by extracting it into plain Rust functions or a separate `services` module. Test those.
- Do not write component-level tests until we hit a bug that they would have caught.
- Prefer integration tests at the driver layer and unit tests at the model layer.

## September stabilization

Browse SQL planning is pure and shared between counts and pages. A validation error clears the count through the existing request-generation failure path and surfaces the error; it cannot fall back to an unfiltered total. Delayed sidebar metadata is accepted only for the same connection allocation, so reconnecting the same saved UUID does not make an old response current. See the tests in `services/browse_query.rs` and `services/database_service.rs`.

Completion identity and reconnect behavior are described in
[architecture](../ARCHITECTURE.md) and constrained by ADR 0008.
