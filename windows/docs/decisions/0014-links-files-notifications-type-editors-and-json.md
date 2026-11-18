# 0014: Links, file types, notifications, type editors and JSON results

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The app opened only `tablepro://share` links and only the files File > Open picked. A connect link, a database URL or a double-clicked `.sql` or SQLite file did nothing, long queries finished silently in a background tab, every cell edited as text, and a MongoDB document read only as a row of cells. The macOS app does all of it.

## Decision

### Links and files

- The core reads `tablepro://` links (`tablepro_core::app_link`, through the FFI's `parse_app_link`) with the macOS grammar: `connect/<id>`, `connect/<id>/table/<name>`, `connect/<id>/database/<db>/table/<name>`, `connect/<id>/database/<db>/schema/<schema>/table/<name>`, `connect/<id>/query?sql=` (51,200 UTF-16 units at most) and `settings[/<pane>]`. A link it cannot read opens nothing and says nothing, as on macOS. `share` links keep their own rule in `tablepro-account`.
- A connect link opens the saved connection, or brings it forward, then opens the table once connected. A database segment opens the connection in that database where each database holds its own schemas, names the schema where databases are schemas, and is dropped where the connection reaches one database (`LinkedTable`). A query link shows its SQL first, as macOS's Open Query from Link, and opens it in a new tab only on Open query; Enter and Escape cancel; a tab that holds exactly that SQL comes forward instead. An id no saved connection has says so under Connection failed.
- The package registers the database URL schemes the core reads. A SQLite or DuckDB URL opens the file and saves nothing, as a double-clicked file does. Any other URL fills the connection form, which shows what the link holds before anything connects.
- The package associates `.sql`, `.psql` and `.pgsql` (a query tab on the connection in front, waiting for one when none is connected), and `.db`, `.db3`, `.s3db`, `.sl3`, `.sqlite`, `.sqlite3`, `.sqlitedb`, `.duckdb` and `.ddb` (a connection to the file that saves nothing, its engine read from the file). A file activation, a protocol activation and a command line (the execution alias, an unpackaged build) give one `ActivationRequest`; a second launch hands it to the first, as share links already did.

### Notifications

- A query the user ran that finishes after Settings > Notifications' threshold (20 seconds unless changed; 5 seconds to 10 minutes as macOS offers) posts a Windows app notification when its tab is not on screen in the window in front: another app in front, the window minimized, or another tab or connection showing. A stopped run never notifies. The title is the connection, the attribution its database, the text the outcome and its duration, or the failure in the results pane's words. A later run in the same tab replaces the tab's notification, and a connection's group together. A click brings that tab forward.
- Where Windows shows no notification for the app (turned off in Windows Settings, or app notifications unsupported), the taskbar button flashes until the window comes forward, and Settings says so with a link to Windows' notification settings.
- The package declares the notification COM activator the Windows App SDK asks a packaged app for; an unpackaged build registers it at launch.

### Type editors

- The core's edit columns say what each holds and an enum's or a set's labels (`EditColumnInfo.kind`, `labels`, `multiple`), so the table tab picks an editor per column (`CellEditors`), as macOS does:
  - a boolean toggles where it is on Enter, F2 or a double-click: NULL and false become true, true becomes false, in the spelling the value had (`1`/`0` or `true`/`false`);
  - an enum with 1 to 100 labels opens a menu of them with the value checked; a MySQL SET opens one with a check per label, and each pick adds or takes out that label;
  - a date opens a calendar, a time a time picker with Set, a timestamp both. They replace the date or the hour and minute and keep the seconds, the fraction and the offset the value had; a new value in a column that keeps an offset takes this machine's.
- Each menu and flyout has Edit as text, and Tab or a new row opens the text box as before (`GridEditStartingEventArgs.InPlace`, `DataGridView.BeginTextEdit`). Escape or a click elsewhere changes nothing, and a pick after the page or the focused cell changed is dropped.
- JSON is checked by the core when the edit is kept (`edit.invalid_json`), shown on the editor as any refused value is.

### JSON results

- Every results pane, a query's and a table tab's, has Data and JSON at the leading edge of its bottom bar, as macOS's result view switcher; the selection summary stays at the trailing edge. The choice is the pane's own, and the grid keeps its rows, selection and edits under the JSON.
- JSON shows the rows the grid shows (`RowsJson`): its columns in its order with hidden ones left out, rows marked for deletion left out, a pending edit's text in place of the value. NULL is null, booleans and numbers are bare with their exact digits, a JSON value (a MongoDB document's nested field included, read by each cell's own kind) nests as written, and anything else is its text. Rows picked on the row numbers narrow it. It stops at 1,000 rows or about 1 MB and says so.
- Text is the pretty-printed array; Tree is a TreeView with a node per row whose children are made as it opens. Copy JSON copies the text. It is written off the UI thread and again after each change to the rows shown.

## Rationale

- The link grammar is logic both apps need, so it is the core's, as the share link rule is.
- A URL from any web page fills a form instead of connecting, so nothing reaches a server the user has not looked at.
- `AppNotificationManager` and `FlashWindowEx` are what Windows offers an app for this; no custom popup.
- Stock WinUI controls for the editors and the JSON view: MenuFlyout with radio and toggle items, Flyout, CalendarView, TimePicker, SelectorBar, TextBox and TreeView.
- The JSON is written with `Utf8JsonWriter` and `JsonDocument`, which keep key order and exact numbers and need no reflection under Native AOT.

## Consequences

- A database URL that matches a saved connection still opens the form rather than that connection, and a network URL cannot open a session that saves nothing: matching a URL to a saved connection lives in `linux/crates/app` today and moves to the core after Linux 0.1.0.
- `tablepro://import`, `integrations/pair` and `integrations/start-mcp` open nothing: the first needs the macOS connection fields (Verify CA, the six Safe Mode levels, icons, AI policy) mapped onto the core's model, the others the MCP server (roadmap C-18).
- Only query runs notify; saves, imports and exports do not yet.
- The calendar shows the years 1800 to 9000; a date outside them opens on today with none selected, and is edited as text.
- The Details pane's fields stay text boxes.
