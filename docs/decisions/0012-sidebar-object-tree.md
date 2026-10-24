# 0012: Show database objects in a collapsible sidebar tree

- **Status**: Accepted
- **Date**: 2026-10-07
- **Clarified**: 2026-10-15 for status. The Decision describes the target design; the Implementation status section records what has shipped. The sidebar still uses a `GtkListBox`.

## Context

The sidebar is one `GtkListBox` fed by a Relm4 factory. Schema and Views headers are list headers, and each header belongs to the first row below it. Hiding rows with the list filter therefore hides the header and its controls, so groups cannot be collapsed (UI-11). Routines, sequences, types and the other catalog objects are reachable only through the Catalog dialog, and the dialog is a flat list per kind.

## Decision

Replace the list with a `GtkListView` over a `GtkTreeListModel`.

1. A node is a connection root, a schema, a group (Tables, Views, Routines, Sequences, Types), or an object. Groups are real rows, so they collapse without affecting their children's controls.
2. Only Tables and Views load with the connection, as today. A group that needs a catalog query loads on first expand, through the guarded connection, with the catalog limit and the cancellation token the Catalog dialog already uses.
3. The search entry filters objects across all groups and expands the groups that contain a match. Clearing it restores the saved collapse state.
4. Collapse state is saved per connection under the existing workspace state.
5. Opening a table, view or catalog object keeps the current messages (`SelectTable`, `EditStructureTab`, and so on). Selection sync maps a tab to its node by schema, kind and name.
6. Row context menus keep their actions. Group rows offer New Table and Table from CSV, which today sit on the schema header.

## Implementation status

The UI-11 slice implements collapsible Tables and Views groups, per-connection collapse state, and search expansion using the existing `GtkListBox` and explicit tree-node model. It does not implement the `GtkTreeListModel` migration or lazy in-place loading of Routines, Sequences and Types. The completed UI-11 record is in the [archived pre-migration ledger](../archive/known-issues-pre-project-migration-2026-10-12.md); those partial results do not mean every part of this decision has shipped. The remaining UI-23 catalog work is tracked in [issue #552](https://github.com/cozyGarage/BookiE/issues/552).

## Alternatives considered

- **Keep the `GtkListBox` and hide rows with the list filter.** Rejected as the target. A header belongs to the first row below it, so filtering hides the header and its controls and groups cannot collapse (UI-11). The shipped slice keeps the `GtkListBox` with an explicit tree-node model as a step, not as the end state.
- **Leave catalog objects only in the Catalog dialog.** Rejected. A flat list per kind makes Routines, Sequences and Types unreachable in context.
- **A generic docking or panel framework.** Not adopted. Add one only when concrete behaviours need it ([Zed panel review](../archive/zed-editor-panel-review-2026-10-22.md)).

## Consequences

- The factory, filter and selection sync are rewritten. The sidebar tests (`sync_sidebar_selection`, the search filter and the header actions) move to the new model first and fail before the swap.
- AT-SPI sees tree rows and expanders, so the installed scenarios that find sidebar entries by name need their roles updated.
- Catalog objects become browsable in place, which closes the sidebar half of UI-11 and part of UI-23.

## Open questions

- Whether schemas of a single-schema connection show as a root row or are flattened, as today.
- Whether grants and roles belong in the tree or stay in the Catalog dialog.
