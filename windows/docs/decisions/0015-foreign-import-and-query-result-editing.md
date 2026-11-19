# 0015: Importing from other apps and editing a query result

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The Windows app imported only TablePro's own connections file, and only a table tab edited its rows ([0006](0006-editing-table-rows.md)). The macOS app imports connections and saved queries from six other clients and edits a query result that reads one keyed table. The core now carries both through the FFI ([core 0033](../../../core/docs/decisions/0033-foreign-import-and-result-editing-through-the-ffi.md)).

## Decision

Each works as the macOS app's does, in Windows sentence case, over the core's review and editor. The logic sits in `src/TablePro.App.Model` with fakes in `tests/TablePro.App.Model.Tests`; the views lay out and ask.

### Import from another app

- The Connections page's Import button and the File menu offer Import from file... (TablePro's own file, as before) and Import from another app....
- A ContentDialog lists the apps Windows has, each with what was found or "Not found on this PC"; Navicat imports an `.ncx` export picked with the system open picker. Passwords and saved queries are options, each offered where the app keeps them somewhere TablePro can read on Windows: decrypted from the app's own files, or DataGrip's KeePass file, whose main key opens with the user's DPAPI.
- The review lists every connection with a check box, what it connects to, its group, the saved connection it matches, and every note the core makes about it. A match starts unchecked and offers Add as copy, Replace when both connect the same way, and Keep existing, add queries when the row brings saved queries. Saved queries follow their connection and say why one cannot import. A bar says when passwords stayed behind.
- Import writes once: the connections, their passwords into Credential Manager, then the saved queries. The Connections page then says what landed. A library changed meanwhile refuses and asks to import again.

### Editing a query result

- A query tab's result edits as a table tab's page does, with the same commands, marks and questions, when the run returned one result set, left no transaction open, ran in the session's own database, and the core proves the result is one keyed table's rows. Otherwise the grid stays read only and trying to edit says why.
- Duplicate refuses a row whose values were read as text that may not name them exactly, as PostgreSQL's for a float, and says so.
- Save writes through the table tab's path, then runs the statement again for what the table holds; the run is not added to the history. A save whose outcome is unknown holds Save back until the changes are discarded, which runs the statement again.
- Save changes, Discard changes and Preview SQL show in the query tab's command bar while its result edits, and the menus' Save, Discard changes, Preview SQL, Add row, Duplicate row and Delete act on it as on a table tab. Ctrl+S in the result grid saves the rows, never the file.
- A new run, a sort, another database or Commit and Roll back ask before they replace rows with pending changes, and closing the tab asks Save, Don't save or Cancel. A switch of database ends the edits, since the statement would be read again elsewhere.

## Rationale

- The core plans every import and every save, so Windows keeps no importer, no SQL and no second copy of the edit rules.
- Stock WinUI controls: ContentDialog, RadioButtons, CheckBox, ComboBox, ListView, InfoBar, ProgressRing and the Windows App SDK's FileOpenPicker.

## Consequences

- DBX's passwords stay behind on Windows, as on every platform, until the core reads its key.
- Pending changes in a query result are not kept in the session file: the rows are gone after a relaunch, unlike a table tab's page.
