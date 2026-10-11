# 0012: Show database objects in a collapsible sidebar tree

- **Status**: Accepted
- **Date**: 2026-10-07

## Context

The sidebar is one `GtkListBox` fed by a Relm4 factory. Schema and Views
headers are list headers, and each header belongs to the first row below it.
Hiding rows with the list filter therefore hides the header and its controls,
so groups cannot be collapsed (UI-11). Routines, sequences, types and the other
catalog objects are reachable only through the Catalog dialog, and the dialog
is a flat list per kind.

## Decision

Replace the list with a `GtkListView` over a `GtkTreeListModel`.

1. A node is a connection root, a schema, a group (Tables, Views, Routines,
   Sequences, Types), or an object. Groups are real rows, so they collapse
   without affecting their children's controls.
2. Only Tables and Views load with the connection, as today. A group that
   needs a catalog query loads on first expand, through the guarded
   connection, with the catalog limit and the cancellation token the Catalog
   dialog already uses.
3. The search entry filters objects across all groups and expands the groups
   that contain a match. Clearing it restores the saved collapse state.
4. Collapse state is saved per connection under the existing workspace state.
5. Opening a table, view or catalog object keeps the current messages
   (`SelectTable`, `EditStructureTab`, and so on). Selection sync maps a tab
   to its node by schema, kind and name.
6. Row context menus keep their actions. Group rows offer New Table and Table
   from CSV, which today sit on the schema header.

## Slices

1. The tree model (nodes, collapse state, search visibility), pure and tested.
   Done in `services/sidebar_tree.rs`.
2. Group and schema rows in the existing `GtkListBox`, one row per tree node, with
   the filter driven by the model. Done on 2026-10-08. The groups are real rows,
   which was the point of the `GtkListView`, so the list view is not needed until
   a group holds lazily loaded children.
3. Selection sync, the context menus and the open messages on the new rows. Done.
4. Lazy catalog groups through the guarded connection. Open, tracked with UI-23.
5. Saved collapse state per connection. Done (`collapsed_groups`).

## Consequences

- The factory, filter and selection sync are rewritten. The sidebar tests
  (`sync_sidebar_selection`, the search filter and the header actions) move to
  the new model first and fail before the swap.
- AT-SPI sees tree rows and expanders, so the installed scenarios that find
  sidebar entries by name need their roles updated.
- Catalog objects become browsable in place, which closes the sidebar half of
  UI-11 and part of UI-23.

## Open questions

- Whether schemas of a single-schema connection show as a root row or are
  flattened, as today.
- Whether grants and roles belong in the tree or stay in the Catalog dialog.
