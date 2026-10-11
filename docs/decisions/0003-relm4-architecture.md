# 0003: Relm4 for application architecture

- **Status**: Accepted
- **Date**: 2026-04-26

## Context

Raw GTK callbacks work for small applications. TablePro has many stateful views, asynchronous database operations, cancellation, tab lifetimes, and cross-component events. Unstructured callbacks would scatter state and make late async results difficult to control.

The application needs explicit state transitions, component ownership, and a standard path from Tokio work back to the GLib main context.

## Decision

The `app` crate uses Relm4 components, messages, commands, and factories on top of gtk-rs.

Component state is private. State transitions pass through component input or command-output messages. Component-scoped async work uses Relm4 commands and returns results to the update loop before widgets are touched.

Raw GTK callbacks remain acceptable inside a component when introducing another public message would make the flow less clear.

## Rationale

Relm4 gives each view an explicit model, message vocabulary, update path, and widget tree. It integrates Tokio tasks with component lifetime and routes results back to the GTK thread.

This structure makes cancellation and late-result handling visible in the component API. Reusable parsing, SQL generation, and state logic can remain outside widget construction and receive focused unit tests.

## Consequences

Accepted:

- Contributors need working knowledge of Relm4.
- Components declare input, output, and command-output types.
- Small UI fragments may become components when they own state or async work.
- GTK widgets stay on the GLib main context.

Gained:

- Explicit state transitions.
- Typed communication between parent and child components.
- Component-scoped async cancellation.
- A consistent path for database results to return to the UI.
- Testable service logic outside widget code.

## Alternatives considered

**Raw gtk-rs callbacks.** Rejected because state and async ownership would become difficult to trace at the expected application size.

**Shared application state behind locks.** Rejected because lock-based global state obscures ownership and allows unrelated components to mutate each other.

**A custom model-view-update framework.** Rejected because it would recreate lifecycle, message, and async integration already maintained by Relm4.
