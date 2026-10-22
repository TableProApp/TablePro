# Beekeeper Studio live UX observation, October 22

This is a visual product observation, not a source audit, correctness review or proposal to copy implementation code. Beekeeper Studio 6.1.6 was viewed on Omarchy at 1920×1200, tiled beside a terminal at about 941×1150. Its PostgreSQL connection used the disposable local `bookie-manual-20261022` fixture at `localhost:15432/tablepro_lab`; the `public.people` table was browsed and no database data was changed.

## Observed interaction patterns

- The connection form gives **Import from URL** a distinct place in the header. Connection type, authentication and endpoint come before credentials. SSL and SSH sections expand inline, growing the form only when their settings are needed. **Test** and **Connect** are separate actions; save details are grouped below.
- The filter UI offers a code-oriented predicate and a visual rule builder using column, operator and value controls. The visual filter is readable at a glance; the code path keeps an escape hatch for users who prefer to type.
- The table header gives column names the primary position and shows the PostgreSQL type as secondary metadata. Key columns get a key icon. Expanding a table in the sidebar shows its fields and their types without leaving the data view.
- The sidebar has a visible database/query/history icon rail, schema groups, table/view icons, and a draggable width. A bottom **Structure** action opens the selected table's structure. A gear menu groups table actions such as import, export, hidden columns and reset.
- At the observed half-screen width, the navigation tree and grid remained usable. The grid showed the active connection, table, filter controls and rows while leaving the surrounding desktop visible through the translucent surface.

## BookiE mapping

These observations do not mean BookiE lacks typed values. B3 protects value fidelity across decode, display, edit, bind and export. That contract is different from showing a declared/result type in the UI. BookiE already retains `ColumnInfo.data_type` and puts the type below the name in grid headers (`apps/linux/app/src/ui/grid/column.rs`); the live Beekeeper view makes the name/type hierarchy and type metadata in the tree more immediately legible. Improve that presentation without weakening or replacing the B3 contract.

BookiE already has both raw SQL and structured filters. The raw SQL entry is primary, with the visual rule editor under **Or use the rule editor** (`apps/linux/app/src/ui/filter_strip.rs`). The opportunity is clearer mode choice and affordance, while keeping both editors synchronized with the same active filter and preserving the existing bound-value and validation behavior.

BookiE already has a toggleable overlay sidebar, schema groups, and table/view icons. Its width is constrained by the overlay split view; it does not provide Beekeeper's obvious drag-to-resize affordance, and its tree does not expose the selected table's columns and types inline. The dedicated Structure tab and context actions exist, but are less directly discoverable from the table view.

## Export scope and recommendation

Show export scope before file format so users know which rows the file will contain. Keep these scopes separate:

1. **Current table page**: export the visible page, including the active table filter.
2. **All matching table rows**: export the table under the current filter and sort. BookiE exposes this action for CSV/JSON, but intentionally refuses it before opening the file dialog until an engine has a tested consistent-snapshot path ([ADR 0014](../decisions/0014-full-table-export-snapshot.md), closed [#553](https://github.com/cozyGarage/BookiE/issues/553)). This is a safety boundary, not a missing menu label.
3. **Query result**: export the result rows and result columns from the SQL query itself, including joins, aliases and computed columns. Do not try to reconstruct a joined result as exports of its source tables. BookiE has loaded-result export; streamed results also offer an all-rows path that reruns the query through a guarded cursor. The UI should say when an action exports only loaded rows or reruns a query.
4. **Filter definition**: saving or sharing a reusable predicate is separate from exporting rows selected by that predicate; label it separately if added.

BookiE currently places page/all-row CSV and JSON actions in the table paginator menu, and offers broader formats in result export. A future UX pass should make the three data scopes visible in one contextual flow, then show format-specific options. Keep full-table export refused until ADR 0014's snapshot guarantee is implemented and tested.

## Follow-up criteria

- Give column names stronger visual priority than type labels, while keeping exact engine types available in headers, tooltips or the sidebar.
- Make sidebar toggle and resize affordances apparent; show table columns and types in the tree when space permits, with a clear Structure entry point.
- Present visual-rule and code filter modes clearly and retain one authoritative filter state when switching.
- Label export scope, loaded-row limits, active-filter behavior and query reruns before the user chooses a file format.
- Recheck all of these in a tiled narrow window and keyboard/accessibility navigation before turning the observations into implementation work. This record does not create backlog acceptance or claim those checks passed.
