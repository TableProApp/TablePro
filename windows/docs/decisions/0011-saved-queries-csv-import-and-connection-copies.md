# 0011: Saved queries, history pins, CSV import and connection copies

- **Status**: Accepted
- **Date**: 2026-11-15

## Context

The Windows app could not keep a query, pin a run in the history, import a file into a table, duplicate a connection or export the connections file. The macOS app has each, and the core now carries them through the FFI ([core 0029](../../../core/docs/decisions/0029-storage-import-and-library-through-the-ffi.md)).

## Decision

Each works as the macOS app's does, with its words in Windows sentence case, over the core's stores and plans; the logic sits in `src/TablePro.App.Model` with fakes in `tests/TablePro.App.Model.Tests`, and the views lay out.

### Saved queries

- Query > Save query... and the editor's menu keep a query tab's whole text under a name, and the history's entry menu keeps a run's. A dialog asks for the name, prefilled from the text as macOS names a favorite, and a folder once there are folders. A name the connection already uses asks before it replaces that query, which keeps its place unless another folder was picked.
- View > Show saved queries opens a pane in the place the history pane takes, one of the two at a time. A tree lists folders, then queries, each in its stored order. Invoking a query inserts it in the editor, as macOS does: it replaces an empty query tab's text, follows a tab's text after a blank line, and opens a new query tab when none is in front. Its menu has Insert in editor, Open in new tab, Copy query, Edit..., Move to and Delete; a folder's has New subfolder, Rename and Delete folder, whose folders go with it and whose queries move to the top level.
- Saved queries belong to a saved connection. A file opened without saving gets a new id each time, so it keeps none. Deleting a connection deletes its saved queries, folders and favourites, as the Linux app does.
- Keywords are kept by the core but not edited here: macOS expands one through completion, which the Windows editor does not have yet.

### History pins

- Pin and Unpin on a run's menu. A pinned run shows a pin, comes first and is never pruned.

### CSV import

- Import CSV... on a table's menu in the object tree. The system open picker chooses the file; a dialog sets the delimiter (Tab for a .tsv), whether the first row names the fields and the text that means NULL, shows how many fields and rows the file has, and maps a field to each column, starting from the fields whose header names a column. A column the server fills is left to it. A field a column cannot read keeps the dialog open with its line and column.
- Safe Mode gates the import as a save: Confirm writes lists the statements first, Read only refuses. The result names the rows imported or, on a failure, the lines of the file that failed and whether the table may hold any of the rows.

### Connections

- Duplicate on a connection's menu copies it with its passwords under "Name (Copy)", then "Name (Copy 2)", right after the original, and opens the form on the copy, as macOS does.
- Export on the Connections page and File > Export connections... write the file Import reads, through the system save picker. It holds no password, and the bar after the export says so.

## Rationale

- The core keeps every saved query, plans every INSERT and copies every secret, so Windows keeps no store and writes no SQL the Linux app does not.
- Stock WinUI controls: TreeView, ContentDialog, ComboBox, CheckBox, InfoBar, MenuFlyout, and the Windows App SDK's FileOpenPicker and FileSavePicker.

## Consequences

- A CSV file past 64 MiB is refused.
- A saved query cannot be dragged between folders yet; Move to moves it, as macOS has no drop target either.
