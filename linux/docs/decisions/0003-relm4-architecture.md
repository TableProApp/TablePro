# 0003 — Relm4 for app architecture

- **Status**: Accepted; superseded for windows and the workspace by [0012](0012-window-per-session.md)
- **Date**: 2026-04-26

## Context

`gtk4-rs` exposes GTK4 as a binding library. Idiomatic use is callback-driven: `widget.connect_clicked(|_| { ... })`. For a small app this is fine. For TablePro's projected ~50 distinct view types, callback-driven code accumulates several recurring problems:

- State scattered across closures, captured by clone or weak reference, hard to reason about.
- No explicit message types; every signal is an ad-hoc callback.
- Async work spawned per-callback, with ad-hoc cancellation.
- Refactoring a view requires changing every signal handler that touches it.
- Testing pure logic requires extracting it from inside closures, by hand.

We need a structure that makes state explicit, decouples view from update logic, and integrates with tokio for async work.

## Decision

The `app` crate uses **[Relm4](https://relm4.org)** on top of `gtk4-rs`. Relm4 supplies:

- **Components** with explicit `Init`, `Input`, `Output`, `CmdOutput` types.
- **AsyncComponent** for components whose `init` or `update` is async.
- **Factory** for homogeneous lists / grids driven by a model.
- **Worker** for background units that do not own widgets.
- **Command output** as the canonical way for async work to feed back into the update loop.

All UI code lives inside Relm4 components. Raw `gtk4-rs` callbacks are reserved for widgets so deep inside a component that exposing a message type would obscure intent. Reviewers flag any component-scale callback that should have been an `Input` variant.

## Rationale

Relm4's component model maps cleanly onto the Elm architecture (Model + Message + Update + View). For a database client with many similarly-shaped views (connection list, table list, query tab, history pane), the structural similarity makes new views cheap to add and easy to read.

The framework integrates with tokio without forcing the developer to think about runtime bridging on every async call. `sender.command(...)` is the one canonical pattern; everything else (cancellation on shutdown, message ordering, sender cloning) is handled by the framework.

Relm4 0.11 (December 2025) is stable enough for production. It is the canonical pattern for non-trivial gtk4-rs apps in 2026 and is actively maintained.

The trade-off is one more layer of abstraction. New contributors must read the Relm4 book before contributing meaningfully — but this is a one-time cost paid once per contributor, not per PR.

## Consequences

Accepted:

- **Mandatory framework knowledge.** Contributors learn Relm4 once before their first non-trivial PR.
- **Reactivity contract.** State changes happen only through `update`. No UI code reaches into a component's state by reference.
- **Component proliferation.** Even small UI fragments may become components. We accept this in exchange for legibility.
- **Some boilerplate.** Each component declares its types up front. We trade a few lines of declaration for a much clearer mental model.

Gained:

- Async work is uniformly handled via `command` + `CmdOutput`. No ad-hoc `tokio::spawn` in handlers.
- State is private to a component. Parent components communicate via typed `Input` and `Output`.
- Refactoring a view is local. The cost is bounded by the component's surface, not by the call sites.
- Pure logic is naturally separable into `app::services` modules and tested in isolation.
- Cancellation on component destruction is automatic (`drop_on_shutdown`).

## Alternatives considered

**Raw gtk4-rs with callbacks.** The default. Lost on legibility and refactor cost at TablePro's projected size.

**Adwaita-swift / SwiftCrossUI.** Would bring SwiftUI-like declarative semantics. Lost on framework maturity and Swift-on-Linux tooling, as documented in [0002](0002-rust-gtk4-libadwaita.md).

**Plain Rust with `Arc<Mutex<AppState>>`.** Some teams ship apps this way. Lost because the lock contention pattern leaks into every callback, async work becomes cumbersome to cancel cleanly, and "shared mutable state behind a lock" is the opposite of a maintainable architecture for a UI app.

**Roll our own MVU.** Tempting; cheap-looking on day one. Lost because it converges on Relm4 within six months and we lose a year reinventing it.

**Floem / Xilem / Iced.** Different framework choices entirely. Lost in [0002](0002-rust-gtk4-libadwaita.md) on the data-grid argument; not re-litigated here.
