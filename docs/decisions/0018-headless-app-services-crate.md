# 0018: Move GTK-free application logic into a headless crate

- **Status**: Accepted
- **Date**: 2026-10-12

### Implementation status (2026-10-25)

Several GTK-free service modules have moved to `crates/app-services`; the crate has no GTK, libadwaita, glib or Relm4 dependencies. The headless tab model and workspace persistence live in `crates/app-services/src/workspace.rs` and `workspace_state.rs`. Completion metadata cache, request deduplication, connection-aware result application and cancellation state live in `crates/app-services/src/completion.rs`, which also performs the controlled column read. The GTK app owns Relm4 task dispatch and routes returned results to the shared index. GTK page handling remains in `apps/linux/app/src/ui/app/workspace_tabs.rs`. The staged migration remains active under APP-MOD in the [post-0.2.0 backlog](../backlog.md).

## Context

`apps/linux/app` is 55,000 of about 110,000 lines in the workspace. Its `services/` directory is about 11,900 lines. Measured on 2026-10-12:

- 33 of the 42 service files (7,771 lines) use no GTK, glib or Relm4 at all: workspace and tab bookkeeping, connection monitoring and retry classification, browse query building, CSV import mappings, named filter presets, column widths, quick switching, approval routing and others.
- 9 files (4,084 lines) touch glib, mostly for configuration paths, `GSettings` and timers.

These files compile and test with the whole GTK application, so a unit test of workspace state waits for the GTK build, and a logic change recompiles the widgets.

Today's bugs show the cost of logic living next to widgets. The tab-close handshake with `AdwTabView`, the preview-tab replacement and the save-then-close steps are all implemented in widget callbacks, so none of them could be tested without a display. Three of those defects reached the installed build before a GTK scenario caught them ([#648](https://github.com/cozyGarage/BookiE/issues/648) and the preview-tab replacement fixed in the same week).

[ADR 0016](0016-governed-consumer-seam.md) already lists "one headless service facade that the GTK app and `bookie-agentd` both call" as an accepted direction. [ADR 0003](0003-relm4-architecture.md) already expects reusable state logic to live outside widget construction. This record makes the boundary explicit.

## Decision

Create a workspace crate for application logic that has no GUI dependency. It may depend on `tablepro-core`, `tablepro-policy`, `tablepro-storage` and `tablepro-transport`; it must not depend on `gtk4`, `libadwaita`, `glib` or `relm4`.

Staged moves, each its own reviewed change:

1. The 33 GTK-free service files move as they are. First batches moved: `approval_wait`, `column_widths`, `config_io` (the glib atomic write is now a std temp-file, fsync and rename), `filter_settings`, `state_file`, `ordered_refresh`, `read_scopes`, `recent_tabs`, `request_generation`, `single_flight`, `structure_tracker`; the app re-exports them from `services` so call sites did not change. Public names and behaviour do not change.
2. The glib-touching files are split: the logic moves, a thin adapter for configuration paths and settings stays in the application.
3. A tab and workspace model is extracted from `ui/app/workspace_tabs.rs`: the list of tabs, which tab is closing, preview versus kept, and the steps "save then close" and "replace preview". It is plain data with transitions that the GTK layer calls and renders. The `AdwTabView` handshake stays in the widget layer and becomes a thin consequence of the model's state.

Constraints that come from the existing ADRs:

- The crate holds only `PolicyGuard`-wrapped connections and adds no second way to execute SQL ([ADR 0016](0016-governed-consumer-seam.md)).
- A move must not change any persisted format, path, keyring schema, application ID or connection identifier. The existing serialisation round-trip tests move with the code and must pass unchanged ([ADR 0009](0009-persistence-and-identity-compatibility.md)).
- The crate does not add a runtime plug-in boundary ([ADR 0001](0001-no-plugin-system.md)).

## Rationale

Unit tests run without a display and in parallel with the UI build. The tab model can be tested for the exact sequences that failed (close while saving, replace a preview, switch connections and back). `bookie-agentd` and the MCP service can later call the same facade as the GUI, which is the divergence ADR 0016 warns about.

## Consequences

Accepted:

- A one-off churn of imports and a larger workspace, with its own coverage and size baselines.
- A boundary that must be kept: reviewers reject a `gtk4` or `glib` import in the new crate.
- The first stage is mechanical and the third is a real refactor of the code that has produced most of the recent crashes; it needs the installed GTK scenarios as its safety net.

Gained:

- Faster feedback for logic changes and a path to testing tab and workspace behaviour without a display.
- A smaller application crate and a smaller recompile when only widgets change.

## Alternatives considered

- **Leave the code where it is and add more GTK scenarios.** Scenarios are slow and flaky under load (TEST-31); they are the right net for the widget layer, not the only one for logic.
- **Split the UI into many GTK crates instead.** Helps compile parallelism but leaves logic and widgets coupled.
- **Move everything at once.** Rejected: it would mix a mechanical move with a behavioural refactor in one unreviewable change.
- **Import dbx's `dbx-core` and `dbx-drivers` (or its runtime plugins and engine registry).** Rejected. They bring application state, dynamic runtimes and a different driver and result contract. `core` stays a domain and driver leaf, because a core-to-driver dependency would reverse today's driver-to-core boundary ([external client review](../archive/external-audit-client-review-2026-10-06.md)); a shared service sits above `core` and the drivers and below the consumer roots, with a dependency allowlist; orchestration lives in this crate, behind the guard of [ADR 0016](0016-governed-consumer-seam.md). Ideas are adopted as behaviour and fixtures only ([dbx review](../archive/2026-10-15-dbx-review.md), "Package and code reuse decisions").
