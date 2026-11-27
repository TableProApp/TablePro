# 0068: The pending-edit tracker and undo move to the core, keyed by primary key

- **Status**: Proposed; implementation tracked in #4647. Supersedes [0019](0019-row-edits-through-the-ffi.md) and the result-editing part of [0033](0033-foreign-import-and-result-editing-through-the-ffi.md) for where the tracker, undo and key identity live.
- **Date**: 2026-11-27

## Context

[0019](0019-row-edits-through-the-ffi.md) kept the pending edits, the undo history and the save on the app side of the FFI. It gave the Windows app a `TableEditor` that is a stateless planner: the app holds the edits, names each row by its place in the result set the page was read into, and calls `plan` with that list to get a `RowSave`. [0033](0033-foreign-import-and-result-editing-through-the-ffi.md) extended the same stateless planner to a query result.

The Linux app does not work that way. Its `TabChangeTracker` (`linux/crates/app/src/services/change_tracker.rs`) is the pending edits, keyed by primary key: a saved row by its primary key tuple, a draft by a tracker-assigned local id. An edit survives sort, filter and paging because it names a row, not a place. The tracker owns undo and redo, orders the save by when each row was last touched, relayouts its edits when the columns are read again, and reports a per-change delta the grid redraws from. 0019 rejected moving that tracker to the core: "an app on the FFI needs only typed text per row, which it already holds."

That left two consequences. 0019 §32: an edit names a row by its place, so the app blocks sort, page and refresh while edits are pending, as macOS does. And the tracker exists twice: a PK-keyed Rust tracker for Linux, and, on Windows, `UndoHistory.cs` plus the app's own position-keyed edit list feeding the stateless `TableEditor`. The macOS app moves onto the core in slices ([0010](0010-macos-on-the-core.md), [0063](0063-the-macos-app-holds-its-results-in-the-core-before-its-engines-move.md)) and would otherwise need a third copy.

The tracker is core logic: it depends only on `tablepro-core` value, column, edit and save types, not on GTK. The maintainer approved reversing 0019 so one tracker serves every app.

## Decision

The pending-edit tracker and its undo move into `tablepro-core`, in an `edits` module, keyed by primary key. One engine serves every app: Linux uses it directly, Windows and macOS reach it through the FFI.

- The module is the Linux tracker ported with its tests: the tracker, the edit command (`TrackerEdit`), the per-change delta (`TrackerDelta`), the undo step (`UndoOp`), the monotonic touch (`Touch`), the column relayout (`ColumnRelayout`), the cell overlay (`CellOverlay`, `CellMarks`) and the save batch shapes. The grid copy and display modules stay in the app.
- Rows are keyed by `RowKey::Persisted(primary key tuple)` or `RowKey::Draft(local id)`. A key value keeps the `Value` it was read with, compared by its bits, so a float, a timestamp with offset or a NaN names one row exactly. Edits survive sort, filter and paging, so the app no longer blocks them while edits are pending.
- The tracker returns coded outcomes, never worded ones. The save's rejection, its result and the cause of an unknown outcome carry a `code()` and typed fields; each app words them, as 0019 and the core's error rule (`core/AGENTS.md`, Principle 5) already require. The app's rejection and outcome types, which the row and structure saves share, wrap the core's coded types and add the sentence.
- The FFI's `TableEditor` becomes stateful and PK-keyed. It holds the tracker for one tab's or one result's edits. When a cell is first edited it reads the row's primary key from the result set, through `value_for_column`, and keeps it, so a later sort or page does not change which row the edit names. A key it cannot name exactly (a float, PostgreSQL's server text for a date) locks the row as 0019 and 0033 already describe. The editor exposes the tracker's commands, its overlays and marks, its pending count, undo and redo, and the save.
- The position-keyed `RowEdit` / `plan` / `RowSave` surface of 0019 is replaced. This is a breaking change to the generated bindings; the C# bindings are regenerated and committed, and the Windows interop and editor model are rewritten against the new surface.
- The Windows app drops `TablePro.Editor.Model/UndoHistory.cs`. Undo and redo are the core tracker's, reached through the FFI.

The save itself is unchanged. `plan_save` over the traced table, the Safe Mode gate at `SafeModeLevel::gate(Write)`, planning again on the writing lease, and the saved / rolled back / unknown result all stay as 0019 and 0033 set them; they now run from the core tracker's change set.

## Rationale

- One tracker, one set of tests, for three apps, instead of a Rust copy and a C# copy that drift.
- Keying by the primary key is what the Linux tracker already does, and what lets edits survive sort, filter and paging, which the position-keyed FFI could not.
- Undo steps the tracker's own maps and touches back, so a save after an undo runs in the order it would have before. Splitting undo from the tracker would leave each app reconstructing core state.
- The outcome and rejection types cross the boundary as codes, so the core keeps no translation catalog and each app keeps its own wording, including the structure save's.

## Consequences

- The FFI API changes shape. The generated C# bindings are regenerated per `windows/AGENTS.md`, Bindings, and committed; the Windows interop and editor model are rewritten; the macOS app reaches the same tracker when its result slice lands (0063) without a third copy.
- An edit no longer pins the result set, so a tab may sort, page or filter with edits pending. A refresh that reads new columns relayouts the pending edits onto the columns of the same name and sets aside an edit that no longer fits, as the Linux tracker already does.
- 0019 and 0033 record, in their Status, that the tracker, undo and key identity move here; the parts of them this ADR does not change (the save planning, the Safe Mode gate, the result-editing locks) stay in force and now run from the core tracker.
- The app's shared `SaveOutcome`, `SaveRejection`, `PendingState` and `UnknownCause` split: the core holds the coded data the tracker produces, and the app holds the wording and the structure-save variants.

## Alternatives considered

- **Keep 0019's position-keyed FFI and a C# undo.** Two copies of the tracker, soon three, and the result set pinned while edits are pending.
- **Move the tracker but leave undo in each app.** Undo has to put the tracker's maps and touches back exactly; an app outside the tracker cannot, so it would rebuild core state.
- **Move the app's worded outcome and rejection types to the core.** The core would carry a translation catalog, which Principle 5 forbids, and the structure save's variants have no place here.
