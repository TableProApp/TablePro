# Changelog: BookiE

## [Unreleased]

### Added

- Positioned SQL errors offer Go to error in the result and Errors views, restoring the editor and placing the caret in the original statement; changed queries and connections require a fresh run.
- SQL editors have a hideable, resizable results panel with an Errors view, maximize/restore controls and Ctrl+J.
- The query editor has visible run scopes and result-file export choices, plus commit-and-close and rollback-and-close controls for an owned session with an open transaction.
- Tables and views expand to show bounded field/type previews, with a Structure shortcut; the docked sidebar has a native resize handle, and the header **Tables sidebar** button shows or hides it at every window width.
- Run (Ctrl+Enter or the Run button) executes the selected text when something is selected, and the whole editor otherwise. It goes through the same guard, policy and audit path as any run.
- The Columns dialog has a Reset button that forgets the column widths you set by dragging for that table.
- The Session button shows how long its transaction has been open ("Session · transaction open · 12 min") once it passes a minute, so a forgotten transaction holding locks stands out.
- F10 opens the main menu, as in other GNOME applications.
- **Audit Log** in the main menu lists the operations recorded in the local audit journal, newest first: connection, who ran it, kind, outcome, rows and duration, with the operation id, policy rule, stored statement text and error on expand. A filter matches operation id, connection, outcome or statement. It verifies the journal chain before showing anything and reports a broken or unavailable journal instead of a partial list. It shows only what the journal stored; statement text is the redacted form. A failed statement's panel has **View in Audit Log**, which opens it with the newest operation, usually the failure, at the top.
- A Preview SQL button in the unsaved-changes bar of a table tab shows the statements and values Save would run, without running them.
- While a query result is locally filtered, its menu also offers **Export All Loaded Rows…** next to **Export Visible Rows…**, so the full loaded result can still be exported. Neither runs the query again.
- The "Token issued" dialog for MCP has a **Copy Token** button, so the token (shown only once) no longer has to be selected by hand.
- Preferences has a **Theme** choice: Default, Ledger (the BookiE brand colours), Catppuccin, Tokyo Night and Gruvbox, each with a light and a dark variant that follows the Appearance setting. The SQL editor, the Structure tab's SQL preview and the JSON cell editor follow the theme too.
- SQLite files open from the file manager (Open With BookiE), and `bookie books.db` or `bookie postgres://user@host/db` opens a database file or a connection URL from a terminal. A URL asks you to confirm before it is imported and connected; a missing or non-database file is refused instead of creating an empty database. A second launch hands its argument to the running window. DuckDB files open from the terminal only.

### Changed

- Large sidebar catalogs filter faster, and saved collapse state cannot hide objects under a schema heading that is no longer present.
- SQL completion checks table names faster in large catalogs.

- Large PostgreSQL query results stream faster while retained pages remain available through the result pager.

- Grid context menus reuse shared keyboard and pointer routing, reducing per-cell allocations.

- Editing a cell or pasting in a table tab no longer rebuilds every loaded row on the page, so large pages with long text values stay responsive.
- Editing a saved table row stays attached to that row when a draft row is inserted above it.
- Keyboard shortcuts use a native adaptive dialog that fits smaller windows and preserves keyboard and mouse gesture descriptions.

- Running statements no longer slows down as the audit log grows. The full audit log is checked when BookiE opens and when you view it; each new record checks only what was written since the last check.
- BookiE now requires GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22 or newer and exits with a message naming the missing versions on older systems; Ubuntu 26.04, Ubuntu 24.04 and Debian 13 are no longer supported.
- The Debian and Arch packages and the AppImage install smaller program files, about a quarter smaller than before.
- SQL execution marks follow statement boundaries, so SQL text inside comments is not marked as executed.
- Export reviews the table-page, loaded-result or query-rerun scope before file format; all matching table rows remain unavailable until consistent snapshot export is qualified.
- Grid headers preserve exact engine type case and keep comments, key and nullability metadata in a native column-details menu.
- Oversized text and JSON cells use shorter visible previews to reduce text-layout work; full values remain available through View Value and Copy Value.
- Column and loaded-row search return keyboard focus to the result grid after selection or dismissal.
- Editing rows with large values uses less temporary memory when verifying the row identity.
- Statements spend less time on sensitive-column checks, and desktop sessions that never mask results skip them.
- Background database work runs on up to four threads, so one slow operation no longer holds up others such as loading the sidebar or another tab.
- Query results hold each cell in less than half the memory, so large results use less memory and more rows fit within the result size limit.

- Large streamed results retain pages within a 64 MiB estimated row-storage budget, keep the newest page and show when earlier rows are no longer available.
- Oversized streamed result rows are rejected before value decoding, reducing memory spikes.
- The Debian package is named `bookie` (`bookie_X.Y.Z-1_amd64.deb`). It replaces an installed `tablepro` package and keeps your settings, saved connections and credentials. The `tablepro` commands remain as aliases.
- Selecting rows with large text or binary cells no longer copies their contents to calculate numeric summaries.
- Large JSON previews use less temporary memory.
- Inspecting a row with oversized cell previews avoids copying the full row contents.
- Multi-line SQL edits update workspace query state once per undoable action, reducing repeated full-script copying.
- Saving workspaces with large SQL drafts uses less temporary memory.

### Security

- Background session cleanup logs diagnostic categories without server error details.

### Fixed

- SQL editor results keep every streamed page within the estimated memory budget, so users can navigate back through completed PostgreSQL results that fit the budget.
- The tab overview no longer shows a duplicate window-close button beside its tab cards.

- A confirmed session rollback clears obsolete query gutter marks, including when a commit request ends in rollback.
- SQL files with lines over 256 KiB are refused before opening to prevent excessive text-layout memory use; the original file remains unchanged.
- Streamed result summaries use singular row and page labels when each count is one.

- SQL completion avoids catalog reads for incomplete table names and coalesces rapid editor changes.
- Connection choices open from the keyboard, mark the selected option and release their popups when the dialog closes.

- Multiline read-only cell previews stay compact instead of expanding query result rows to many text lines.
- Closing streamed query results releases hidden page labels instead of accumulating retired tab widgets.
- Closing a SQL editor releases its syntax analysis engine so background highlighting does not keep growing memory for a closed large script.

- Save-conflict messages keep the recovery advice without a redundant failure prefix or unrelated session warning, and save errors no longer double sentence-ending periods.
- Restoring older workspaces skips empty table-structure tabs while keeping the active editor aligned and the empty workspace usable.

- Export cleanup warnings omit database error details that could contain private query text or values.
- Exporting loaded results avoids two extra copies of the result data while choosing and writing the destination file.

- Keyboard cell menus refresh reference and loaded-row export availability for the current cell and filter.
- A SQL editor result that was cut short by the result size limit now says so and shows how many rows were loaded, instead of only after sorting or filtering.
- BookiE and `bookie-agentd` no longer crash when the terminal or pipe receiving their log output closes.
- In a table tab, the total row count no longer briefly shows the count from before a filter change or refresh.
- The Rows per page choice in a table tab works after the first page failed to load.
- The "Couldn't load rows" page in a table tab has a Retry button.
- The multi-row selection badge no longer suggests pressing Delete on read-only connections or tables without a primary key.
- PostgreSQL dump and restore retries briefly when its client executable is temporarily busy starting.
- Screen readers name the page navigation and export buttons of a table tab and read the Rows label with the page-size choice.
- When a connection had more than 32 open tabs, the table tabs left out on the next start are now reported in a notice instead of disappearing silently. Query editor tabs are always kept.
- Query cursor cleanup warnings use diagnostic codes without including database error payloads.

- Copying rows and pasting them back into the grid keeps NULL, empty text and text such as `\N` unchanged. Previously empty text pasted as `""`, and a cell holding `\N` could swap with a NULL.
- Undoing or redoing a cell edit on a saved row no longer replaces the row's stored value with an unsaved one, so a later edit is no longer lost or rejected as a conflict when saved.
- Closing a table browse tab releases its widgets and loaded rows.
- PostgreSQL: a table named without its schema is found through the whole `search_path`, as PostgreSQL itself resolves it. Before, only the first schema on the path was searched, so SQL completion showed no columns (and structure lookups found nothing) for a table that lives in a later schema.
- Removing a saved connection asks for confirmation once and preserves the database.
- Saved connection rows show environment and engine names beside the endpoint, keep connection names readable in narrow lists, and place secondary actions in a menu.
- SQLite refuses to drop a table in an attached database while other tables there still reference it, so their ON DELETE actions no longer empty those tables.
- The Structure tab lists MySQL tables that have an index on an expression, and Show CREATE TABLE explains that an expression index cannot be recreated instead of writing it as a column index (MySQL, PostgreSQL, SQLite).
- Open tabs, the active tab and sidebar group state are saved per database. Switching a saved connection to another database no longer restores the first database's tabs against the second, where a same-named table could show with the wrong page, sort or filter. Each database gets its own tabs back when you return to it; workspaces saved by earlier versions restore for the database you connect to first.
- Table browsing identifies when the result byte limit cuts a page short.
- Next page in table browsing continues from the first row not shown when the result byte limit cut the page short, instead of skipping the remaining rows or disabling Next.
- The main window has a minimum size, which stops repeated libadwaita warnings on older libadwaita releases.
- Choosing a kind in the Catalog dialog no longer resizes its dropdown and shifts the schema search field.
- SQL completion popups remain usable when suggestions disappear and return, instead of triggering a GTK critical or showing a blank popup.
- Spaces pasted around a connection's host are removed before connecting; database names and file paths are kept exactly as typed.
- A PostgreSQL `VOID` result, such as `SELECT pg_sleep(0)`, shows as an empty value instead of undecodable.
- In a window narrower than 960 px the tables sidebar no longer opens over the workspace after connecting, where it swallowed the first click on Run and the other editor controls. A **Tables sidebar** button in the header opens it on demand, and the sidebar returns by itself when the window is widened.
- Closing SQL editors releases their retained query text and search state.
- SQL execution waits for a dedicated session to open, so an immediate query cannot run outside the selected session.
- Opening a connection that has no stored password no longer makes the system keyring ask you to create a new keyring. Reading or removing a password now uses the keyring only if it already exists; the keyring is created only when a password is actually saved.
- Loading a cell's full value (row inspector, View Value) is cancelled when its tab closes, the connection changes or a newer value is opened, instead of running on until its timeout.
- A schema change stops the SQL-completion column lookups still running from before it.
- The database switcher ignores, and stops, a database list still loading from the session before a database switch.
- A cancelled Structure tab load no longer replaces the newer one.
- A new empty editor tab takes the first free "Query N" title instead of counting open editors, so closing Query 1 and opening a new tab no longer produces a second "Query 2".
- Closing a result grid releases its selection and row inspector.
- Long text previews show embedded NUL characters visibly instead of cutting off the remaining preview.
- Streamed result pages wait until their first display frame before building a grid, avoiding work for discarded pages.
- SQL query controls and secondary tools use separate rows to stay reachable in narrow editor panes.
- Discarding changes to a SQL file closes its tab without reopening the same save prompt.
- PostgreSQL queries ending on a full result page complete without a false column-change error.

## [0.2.0] - 2026-10-23

Source version **0.2.0** (`Cargo.toml`, inherited by every workspace crate). This section is the user-facing map for the 0.2.0 release since the last tagged package, [0.1.5](#015---2026-09-27). Compare: [`linux-v0.1.5...linux-v0.2.0`](https://github.com/cozyGarage/BookiE/compare/linux-v0.1.5...linux-v0.2.0).

### Added

- Import accepts Excel .xlsx files: the first worksheet with data is read with size, row and column limits and then mapped like a CSV file.
- CSV export has Keep plain numbers as they are: text such as -5 or +1.5 is written without the spreadsheet apostrophe so it re-imports into numeric columns, while other formula-like text is still prefixed.
- Copy as in the grid menu also offers UPDATE Statement and DELETE Statement for a row, found by its primary key. Tables without a key refuse with a message.
- CSV import can set the quote character, backslash escaping of quotes and the file encoding (UTF-8, Windows-1252, UTF-16); a file that is not UTF-8 opens with a matching encoding selected.
- The sidebar table menu has Truncate Table, which asks for confirmation and runs through the same guard as other statements. SQLite is refused because it has no TRUNCATE.
- The sidebar table menu has Rename Table. It asks for the new name and is refused while the table has open tabs, so no pending changes are lost.
- MongoDB connections have an optional Authentication database field, for a user defined in `admin` while the Database field names the database to browse; saved connections and bundles carry it.
- PostgreSQL query cancellation through PgBouncer without interrupting another client's work.
- Unsorted keyed table browsing can move backward through deep pages and jump to the last page using primary-key seeks while keeping rows in ascending key order.
- Arch packages include a build-input manifest with source and dependency archive checksums, package versions, and toolchain details.
- The Arch package includes generated license texts and versioned attributions for the Rust dependencies used by its application binaries.
- Preferences has **Reuse one tab when opening tables**. Turn it off to give every table opened from the sidebar its own tab; an already-open table is still selected instead of duplicated.

- Reveal Table in Sidebar (Ctrl+Shift+L, or the main menu) opens the collapsed groups around the open table, clears a search that hides it, and scrolls to and selects it in the sidebar.
- Opening a new SQL editor while disconnected now shows the editor and removes completion suggestions cached from the previous connection.
- When a query stops at the query timeout, the editor offers Run again with a longer timeout, which runs the same query once with four times the timeout and leaves the saved timeout unchanged.
- A connection marked Production now shows a red Production badge and a tinted header bar, and its window title starts with [Production], so it stands out from other connections.
- SQL completion inserts complete dialect-quoted table and column names, preserves aliases, and offers scoped metadata instead of arbitrary editor words.
- Large SQL query results stream in bounded pages, can be pinned, and can be fully exported by running the guarded query again.
- CSV imports into PostgreSQL, MySQL/MariaDB and SQLite can preserve explicit auto-increment values from mapped columns; generated columns remain database-owned.
- Editable text and JSON columns open a bounded full-value dialog; JSON input is validated, source-text JSON retains its exact text, and Format JSON makes semantic formatting changes visible before Apply.
- At narrow window widths, the navigation sidebar collapses and the Fold block and Unfold all toolbar buttons hide so the remaining editor controls stay in view; their keyboard shortcuts still work.
- Preferences gives appearance its own page and explains the data-browser and editor settings more clearly; About separates project credits from third-party attribution.
- Switching database drivers keeps custom connection values and updates fields that still use the previous driver's defaults.
- Duplicating a password-authenticated connection with a saved password opens the copy's credential form so its password can be entered before connecting.
- PostgreSQL results and edits support `json[]`, `jsonb[]`, `int4range`, `int8range` and `point` values.
- SQL editors can collapse multiline SQL blocks at the cursor and unfold them from the gutter or toolbar.
- Pressing Enter in a connection text field now activates Connect.
- SQL query and pinned result grids can filter loaded rows by a cell's native value without running the SQL again; the grid shows the visible and loaded counts.
- View Value shows pending grid edits, including long text and NULL, before they are saved.
- Find in Loaded Rows searches full loaded text and JSON values beyond the truncated grid preview.
- SQL result filters and sorting stay in place when the same statement is rerun or its result is pinned or unpinned, and selected rows stay attached to the same materialized result.
- Plain-clicking a table opens a temporary preview tab that the next table click can replace; preview tabs are not restored after restart, while editing or choosing **Keep Tab** makes one persistent.
- PostgreSQL and SQLite query plans open in a Tree tab of the Explain dialog.
- Ctrl+V pastes tab-separated text from a spreadsheet into grid cells, all or nothing.
- When a cell belongs to multiple foreign keys, Go to Referenced Row lets you choose the target table.
- ENUM and SET cells on MySQL and MariaDB, and enum cells on PostgreSQL, are edited from a list of members.
- The keyboard selection in an ENUM picker starts on the cell's current member.
- A preference chooses how NULL is displayed in the grid.
- Browse filters can be saved, applied, renamed and deleted per connection, schema and table.
- MySQL and MariaDB connections can use a local Unix socket file, saved with the connection and exported in version 3 connection bundles.
- Query history now opens in a docked panel beneath the workspace, which stays visible while you search and reopen queries.
- Connection subtitles use readable database engine names and avoid repeating the engine when the server version already includes it.
- SQL result grids can sort supported, homogeneous typed columns in memory without re-running the SQL statement; SQL NULL values stay last in either direction.
- SQL editors can show a second side-by-side view of the same query, with independent scrolling and shared edits.
- PostgreSQL schema groups can now be hidden per connection and restored from the schema filter menu.
- PostgreSQL TLS verification now trusts the operating system certificate store when no custom authority is configured.
- MongoDB table browsing now seeks deep pages in `_id` sort order, including collections with mixed key types.
- MongoDB table browsing applies supported column sorts on the server and keeps the requested order across pages.
- MongoDB offset and `_id` keyset pages apply equality, inequality, comparison, range, set-membership, null, `LIKE` and `ILIKE` filters with SQL null behavior.
- Concurrent MongoDB first-page requests now share one schema census and retain the union of types observed across pages.
- Saved SSH hops now have stable IDs and credential revisions, with separate Secret Service operations for per-hop passwords and key passphrases. Legacy connections-file v1 data loads and migrates to v2 on save. Connections use those per-hop secrets for transport; editing a jump chain in the form remains disabled until that editor lands.
- Encrypted connection bundles now write format version 3 with local MySQL socket paths and each versioned SSH hop's password or key passphrase; version 1 and 2 imports remain supported and plaintext bundles still contain no credentials.
- MongoDB browse long text, binary and structured values use guarded, ObjectId-safe `_id` refetches for full values.
- Redis string values now use guarded, byte-safe key refetches for full values; collection and container debug strings remain untruncated.
- SQL-backed table browse cells over 8 KiB now show a typed preview with the original byte count; View Value refetches through the guarded connection by primary key.
- Arbitrary SQL result grids now preview long text, JSON and binary cells with byte counts; View Value reads the complete value from the guarded result already in memory.
- Previewed grid cells no longer keep a second full value in each cell widget.
- Materialized result-grid rows share their source values, reducing duplicate memory for long cells while preserving pending edits on replacement.
- Overlapping View Value requests discard stale replies so an older fetch cannot replace the latest requested cell.
- Long ClickHouse cell values can be opened in View Value up to 12,000 bytes.
- DuckDB BLOB values support guarded exact refetch of the full value from the database.
- MySQL and MariaDB CHAR results preserve `PAD_CHAR_TO_FULL_LENGTH` padding, including VARCHAR, empty values and NULL.
- MySQL and MariaDB CSV imports preserve impossible calendar dates accepted by `ALLOW_INVALID_DATES`.
- PostgreSQL CSV imports preserve native BC date, timestamp and timestamptz values.
- CSV imports into existing tables can remember and restore column mappings for a specific connection and table.
- The sidebar groups tables and views under schemas and groups with object counts; a click collapses a group, a search expands the groups that match, and the choice is remembered per connection.
- A Pin results button in the SQL editor keeps the current results above the results of the next run, and unpins them again.
- Each statement of a script gets a gutter mark after a run: a tick for a statement that returned, a cross for one that failed.
- MySQL ENUM and SET grid edits refuse malformed metadata and preserve escaped labels.
- A failed PostgreSQL statement in the SQL editor shows the line and column of the error.
- A failed statement in the SQL editor offers a Copy error button.
- Selecting several rows and opening the selection badge shows each numeric column's count, sum, average, min and max, with NULLs skipped and a Copy summary button.
- A connection's colour tag now also paints a strip above its workspace tabs, so a window shows which connection it belongs to.
- The connection colour picker shows translated, title-case colour names.
- PostgreSQL shows unsupported built-in ranges explicitly; supported empty ranges stay distinct from SQL NULL.
- MongoDB and Redis browse pages use native fetches when available; MongoDB cursor values remain visible until refresh, and approved edits preserve sibling fields.
- Result column headers show the column type and mark primary-key and foreign-key columns.
- Redis key browsing preserves arbitrary-byte keys and non-UTF-8 string values, and fills requested pages across partial SCAN batches.
- MongoDB filters distinguish missing fields, explicit BSON null, and ordinary values.
- SQL Server query batches now preserve ordered result sets through the policy guard, editor, MCP query responses, and JSON export; MCP shares its row cap across sets, and CSV export refuses multi-set results rather than dropping data.
- ClickHouse Enum8/Enum16 values, arrays and maps preserve declared labels, empty strings and SQL NULL through supported reads and exports; writes refuse undeclared or lossy values.
- PostgreSQL custom enum arrays preserve labels, NULLs, dimensions and bounds through results, parameters and typed CSV import.
- Copy-as-INSERT and SQL exports now let PostgreSQL and SQL Server generate fresh identity values; MySQL continues to preserve explicit auto-increment values.
- Table tabs have a Row inspector pane that shows every column of the selected row with its type and full value.
- The SQL editor shades the statement under the cursor so you can see what Run Statement at Cursor will send.
- The SQL editor jumps to the next or previous statement with Alt+Shift+Down and Alt+Shift+Up.
- Preferences has an Appearance setting to follow the system or always use the light or dark style.
- Result tabs of a script are named after the statement and table, such as 2 · SELECT users (12), instead of Result 2.
- A script with more than five statements shows its results in a drop-down instead of a row of buttons that overflows the window.
- Preferences has an opt-in Vim keys setting for the SQL editor, applied to editors opened afterwards.
- A table remembers the column order you drag it to, per connection.
- Find in Loaded Rows (Ctrl+Alt+F or the grid menu) lists the loaded rows that contain a text and selects the one you pick.
- Holding Ctrl and pressing Tab cycles through recently used tabs; releasing Ctrl opens the selected tab.
- Preferences has an Editor font family setting; an empty value keeps the system monospace font.
- PostgreSQL `bit[]`, `varbit[]`, `citext[]`, `pg_lsn[]`, `macaddr[]`, `macaddr8[]`, `inet[]` and `cidr[]` preserve values and SQL NULL through typed results, bindings, keyed edits and CSV import.
- The result grid's cell menu also opens with Shift+F10, and the editor find fields have accessible names.
- Sidebar table search and saved-filter naming fields have accessible names, and connection colours can be chosen with an accessible button and palette.
- Result grids have a Columns… menu entry to hide and show columns; the choice is remembered per table and at least one column always stays visible.
- Table browse refreshes omit hidden non-key columns while retaining keys; full-row copy and current-page export refuse incomplete rows.
- PostgreSQL `xml[]` preserves values through query results, keyed edits and supported file exports.
- PostgreSQL enum and domain values keep their schema and declared type when names are shadowed or the role has restricted privileges; enum CSV imports distinguish blank cells from NULL.
- PostgreSQL composite arrays, `money[]` and `point[]` remain explicitly unsupported and cannot be written lossily.
- Result grids have View Value…, which opens the whole cell in a read-only window: pretty-printed JSON, a hex dump for binary data, and a Copy value button.
- A saved connection that is still connecting can be cancelled from the progress notice.
- Starting BookiE while it is already running now brings the existing window forward instead of exiting silently.
- The SQL editor has find and replace: Ctrl+F opens a search bar with next, previous, a match count, Replace and Replace All.
- The connection form starts on PostgreSQL, offers file pickers for SQLite and DuckDB files and for the TLS certificate authority, and a TLS failure now says to check the TLS setting.
- A failed connection from the saved list now offers Try Again and Edit Connection instead of only Close.
- Saved connections can be edited from the welcome list, including their password, TLS, timeouts and single-hop SSH settings.
- PostgreSQL enum results, filters, edits and CSV workflows preserve literal `NULL`, empty labels and SQL NULL. UUID-domain and array-domain values retain their declared types, and wide `NUMERIC` grid edits remain exact.
- SQLite STRICT `ANY` values retain their storage classes and SQL NULL through function results and typed CSV restore; JSON aggregate output remains exact in JSON, CSV and XLSX exports.
- DuckDB `TIME_NS` and `TIMESTAMP_NS` preserve all nine fractional digits on parameterized inserts and updates.
- The editor find bar has Match case and Regular expression toggles.
- A Switch database button in the window header lists the databases the account can open on PostgreSQL, MySQL, SQL Server, ClickHouse and MongoDB, reconnects to the one you pick and remembers it for that saved connection.
- The Connect button in the connection form becomes Cancel while it is reaching the server, so a slow or unreachable host no longer has to be waited out.
- The MCP tool list now carries read-only and destructive hints, so clients can tell the metadata tools from the ones that run SQL.
- PostgreSQL databases can be backed up to a file and restored from one with the installed client tools, through SSH tunnels and TLS; restores need approval and both are audited.

### Changed

- SQL completion creates suggestion objects as they are requested, reducing initial allocations for large catalogs.
- The translation template is now named `bookie.pot` and is generated rather than committed, so it no longer conflicts between changes; each release attaches it.
- Opening a SQL editor tab moves keyboard focus into the query instead of leaving typing in the sidebar search.
- Closing or replacing table and query results releases associated data instead of accumulating memory.

- Manually resized and restored grid columns keep their width when the window grows; unsized columns continue to fill the available space.
- Imported connection URLs preserve supported TLS settings and reject options they cannot preserve.
- Ending an aborted PostgreSQL editor transaction reports that it rolled back instead of saying its changes were committed.
- PostgreSQL session audit records distinguish committed transactions recovered through savepoints from aborted transactions that roll back.

- Running a query again keeps the previous result on screen, dimmed, until the new result, error, cancel or timeout page replaces it, instead of leaving a blank area.- An unresolved write outcome blocks governed writes only on its saved connection; a journal failure or unresolved process-wide operation still blocks writes everywhere.
- Typing in a table cell is included in unsaved changes before a tab closes, a connection disconnects or a preview tab is replaced.
- Refreshing a table waits until its pending save finishes, so a failed save does not lose edits.
- An unresolved write outcome blocks governed writes only on its saved connection; a journal failure or unresolved process-wide operation still blocks writes everywhere.
- A write refused because another write is still in flight no longer disables later writes on that connection; unresolved outcomes remain fail-closed.
- MySQL sessions allow locking reads, user-variable assignments, savepoints and supported SHOW forms inside an open transaction; rollback does not undo session effects such as user variables or named locks.
- The MCP token dialog reports whether the one-time token was saved in the system keyring and explains what to do if it was not.
- The Keyboard Shortcuts window splits table browsing into shorter groups, describes mouse selection gestures separately and combines repeated context-sensitive save, undo and cancel actions.
- About, Arch package, Flatpak, and translation metadata link to the BookiE repository.
- Full-table export is refused before a destination file is chosen when a verified read snapshot is not available; current-page and loaded query-result exports remain available.
- MCP data results use the versioned `bookie-tagged-v1` format so clients can preserve exact numeric values.
- Redis in this development line stays a single host/port endpoint; Sentinel and Cluster topologies stay deferred.
- A successful rollback request now warns that session state and other non-transactional side effects may remain after a failed save.
- Startup opens the query history database while the rest of the application starts instead of waiting for it first.
- The Debian package installs its programs without debug symbols, which makes the installed files about a quarter smaller.
- The time shown for a statement no longer includes the wait for your approval on a guarded connection.
- MongoDB browse pages now use a bounded schema sample and stable `_id` paging instead of scanning the full collection for every page.
- Create table from CSV now explains that ClickHouse, MongoDB and Redis connections cannot do it, and DuckDB gets its own JSON type name.
- The Keyboard Shortcuts window groups actions clearly and uses the standard GTK layout.
- Large results use about 45% less memory in the grid because rows are built only when they scroll into view.
- Browse results share their in-memory query result; GTK row objects are created when the view requests them. This avoids eager per-row GObject creation but does not page database rows or bound result memory.
- Grid context-menu CSV copies encode SQL NULL with a collision-free marker, keeping it distinct from empty text and enum labels; formula sanitization remains enabled.
- CSV file and MCP exports show the null marker used for SQL NULL cells and choose one that does not collide with exported text values, so the matching import preserves empty text and marker-shaped labels. Turn off spreadsheet-safe text to round-trip formula-shaped values literally.
- Markdown table exports and copies quote text cells and escape table/inline markup, keeping text labels such as `NULL` distinct from SQL NULL.

### Fixed

- Large SQL files skip automatic editor analysis above 200,000 UTF-8 bytes while preserving their full text for editing, saving and execution.
- Streamed queries build a retained page’s grid only when it is first displayed, avoiding work for hidden pages.

- Large SQL results use Previous/Next controls with row ranges and state when earlier rows are no longer retained.

- Failed MCP token guesses can no longer lock out a valid token: the shared failed-attempt limit applies only after a token fails verification.
- ClickHouse connections that name no certificate authority now trust the system certificate store, so corporate authorities installed on the machine verify; the bundled roots remain the fallback.
- A MySQL CLONE INSTANCE statement with IDENTIFIED BY is no longer saved in query history.
- A named pipe or device chosen as a TLS CA, certificate or key file is refused instead of hanging the connection.
- A TLS certificate failure no longer tells you to set TLS to Disabled; only a server that does not support TLS gets that suggestion.
- PostgreSQL pooled connections are reset (`DISCARD ALL`) when returned, so a `SET`, temporary table or prepared statement from one editor statement no longer leaks into later reads on the same connection. Session mode keeps its own state.
- Stopping or timing out a DuckDB query now interrupts it on the engine, so the connection is free again at once instead of waiting for the query to finish.
- ClickHouse grid edits and deletes check that the key matches exactly one row and refuse, changing nothing, when the non-unique sorting key matches several.
- SQLite refuses to drop a table that other tables reference and names them, instead of silently running their ON DELETE actions on the child rows.
- Pasting rows copied from a BookiE grid restores values that start with `-`, `+`, `=` or `@` and turns the copied NULL marker back into an empty (NULL) cell.
- Restoring a workspace with more than 32 tabs on one connection keeps every SQL editor and drops table tabs first.
- Clearing a cell in a required text column saves an empty string instead of refusing the edit with "Field is required".
- The connection dialog puts Test on the left and Connect on the right with a centered title; its dropdown choices, port and timeout boxes have an arrow or room around them.
- A long message in the SQL editor toolbar, such as the notice after cancelling a large query, is cut with an ellipsis instead of pushing Pin results, Session, Explain, Run and Split off screen; the full text is in the tooltip and on the Status page.
- A `USE` run on a pooled MySQL connection no longer changes which database later catalog reads and queries see: each pooled connection returns to the configured database before it is reused.
- Keyboard run shortcuts no longer start another execution while a query is active.
- After a tunnel drop during a Session transaction, a fresh editor session can run read queries again: ending its read-only snapshot with ROLLBACK is no longer refused by the earlier unresolved write, while commits and writes on that connection stay blocked.
- Cancelling a PostgreSQL backup removes its partial file; a started restore that is cancelled or fails leaves governed writes on that connection blocked after reconnect while its outcome remains unknown.
- Read-only connections refuse grid edits through alternate actions while still allowing local drafts to be discarded or undone and redone without changing stored data.
- Structure column expanders now point right when collapsed and down when open.
- A database switch rejected during another connection change no longer alters the saved connection.
- On MySQL and MariaDB, `--` followed by a character other than a space, such as `SELECT 5--2`, no longer hides the rest of the line as a comment, so the following statements are found and checked separately.
- A save or import whose connection was lost during a statement could be recorded as rolled back, and agents were told the rollback was confirmed; it is now recorded as an unknown outcome, and an import batch that partly applied is no longer recorded as rolled back.
- Closing a retired database session after a tunnel loss no longer sends ROLLBACK through that unusable session; the transaction outcome remains unknown.
- A PostgreSQL identifier containing dollar signs, such as `my$a$b`, no longer makes the editor read the rest of the script as one quoted statement.
- The error location for a PostgreSQL SELECT shown page by page pointed past the end of the statement; it now marks the right place.
- Renaming a MySQL table in a database other than the connection's moved it into the connection's database, and renaming a ClickHouse table failed.
- In a Session editor tab, a PostgreSQL SELECT with a typo or an error partway through no longer ends the session and its temporary tables, and Export all rows of such a result reads through the same session.
- A MySQL `TINYINT(1)` holding a value other than 0 or 1 showed as true, and saving another change in its row could report that the row had changed; it now shows the stored number.
- SQL Server `real`, MySQL `FLOAT` and DuckDB `FLOAT` values showed extra digits, such as 0.10000000149011612 for 0.1, in the grid, copies and exports.
- Streamed query results: a result of exactly a whole number of pages no longer ends on an empty page, a failed or timed-out stream is shown first, a stream still loading can no longer be pinned as if complete, and pinned results stay visible while a query runs or after it is stopped.
- MCP clients with valid tokens were refused with a rate-limit error once all agents together exceeded one token's per-minute limit; only failed sign-in attempts now count toward the shared limit.
- Dropping a SQL Server column that has a default, or changing its type, failed in the Structure tab; the default is now removed first and kept after a type change.
- Importing a connections bundle or deleting a connection while the same connection was being saved could leave its record and its saved passwords from different edits; these now take turns.
- Saving the same connection from two windows at once, or switching its database while an edit was saving, could lose one of the changes or pair one edit's server with the other's password.
- A SQL Server connection with TLS set to Prefer failed against a server that offers no encryption; it now continues without TLS, as Prefer does for PostgreSQL and MySQL, and a server that refuses encryption under Require reports a TLS failure.
- A ClickHouse, Redis or MongoDB save that failed partway now says the changes before the failing one were applied, and the audit journal no longer records it as rolled back.
- Creating a SQLite table with a foreign key in the Structure tab failed; the key is now declared with the table, and Add Foreign Key is unavailable on existing SQLite tables, which cannot take one.
- SQLite table, index and foreign-key metadata now remains available when user tables use built-in PRAGMA function names.
- A read-only query that failed, hit its row limit or lost its connection no longer blocks saving changes until the next reconnect.

- PostgreSQL completion keeps quoted case, dots, spaces and embedded quotes distinct when loading table columns.
- PostgreSQL errors no longer replay queries or writes merely because their error code resembles a stale prepared plan.
- Browse pagination now disables Next at the known end of a table and ignores exhausted-page navigation requests.
- The CSV import progress dialog now closes after the import completes or is cancelled.
- Explain view tabs and the schema filter button now use icons available in Adwaita and Yaru themes.
- The Explain plan window now closes when you press Escape.
- Pinned results no longer shift the statement numbers shown for a new script's results or errors.
- View Value wraps long unbroken values without adding display-only hyphens.
- Editing a table's structure keeps the Structure label on its tab when unsaved changes are marked.
- Open Browse tabs reload their rows after Structure changes so grid headers and SQL exports use the current column names.
- Opening the filter strip with an active structured filter now expands the rule editor instead of showing an empty raw WHERE field.
- Restoring an editor no longer triggers a GTK sidebar layout failure before the window has completed its first layout.
- PostgreSQL `SELECT ... FOR UPDATE` statements are treated as writes and follow configured approval and read-only rules.
- PostgreSQL displays `interval` and `timetz` values and formats `float4` values consistently, including inside point and float arrays.
- PostgreSQL grid filters on real-valued columns compare values using their native type, and stale prepared plans no longer reuse an incompatible result type.
- PostgreSQL temporal column changes preserve the declared precision and retain the existing default expression.
- Narrowing a column type from the Structure tab no longer silently truncates stored values.
- Structure comparisons detect an index or foreign key replaced under the same name, and remove the constraint that owns an index when requested.
- Adding a primary key or identity to a new column preserves the requested property; toggling either on an existing PostgreSQL column is refused when the operation cannot be applied safely.
- PostgreSQL XML, OID, `tsvector` and geometric values now decode or write through their exact text forms where the driver supports them.
- PostgreSQL `json` values retain their original text through result decoding and value carriers.
- PostgreSQL EXPLAIN runs the statement at the cursor rather than the entire editor buffer.
- Undoing an edit that reverted a cell restores the earlier pending edit.
- Draft cells explicitly set to NULL override the database column default.
- Local text sorting follows the system locale, and sorting a truncated result warns that only loaded rows are included.
- Spreadsheet paste preserves leading quotes and round-trips copied cell text, including embedded line breaks.
- A failed cell save no longer allows a second save or a new edit to overwrite its in-flight state.
- A busy connection pool is reported as busy rather than as a disconnected connection.
- Corrupt saved window or column sizes are clamped, and invalid geometry no longer overwrites the last valid layout.
- Exporting query results no longer duplicates the selected file extension when the file chooser adds it automatically.
- Screen readers can activate the connection form's Driver, Endpoint and TLS selectors and identify its port and timeout inputs.
- The docked query history panel rebuilds each time it opens, so its connection filter lists connections added, renamed or deleted since it was last shown.
- PostgreSQL browse pages for tables without a primary key now use the row locator as a stable ordering tie-breaker, preventing duplicates and gaps between static pages.
- Filtering a PostgreSQL column of type `time`, `timetz`, `interval`, `inet`, `bit`, a range, an enum whose name contains a type word such as `update_kind`, or a domain now builds a valid filter instead of misreading the value or comparing it as text.
- CSV import into PostgreSQL reads enum and domain columns, bit strings and ranges as text, so an enum named like `maintenance_status` or a `bit(3)` value no longer fails as "not a whole number".
- Create table from CSV keeps zip codes, phone numbers and other identifiers with a leading zero or plus as text instead of turning `01234` into `1234`.
- Identifier quoting keeps control characters in a name instead of removing them, so a statement can no longer target a different table than the one named.
- PostgreSQL edits that set a cell to NULL, compare an old NULL, leave a column NULL in a new row, or import an empty field into an integer, date, uuid, boolean, numeric, JSON or inet column no longer fail with "expression is of type text".
- After a table changes (for example a column is added from the Structure tab or another client), `SELECT *` on PostgreSQL shows the new column instead of failing with "cached plan must not change result type" on every refresh.
- PostgreSQL grid edits, inserts, key lookups and deletes now work for `inet`, `cidr`, `macaddr`, `interval`, `bit`, `varbit`, padded `char(n)` keys and `json` columns. XML, OID, `tsvector`, `regclass`, `char`, `record`, `hstore` and `ltree` scalar results now use PostgreSQL's text representation; supported types can be bound back through text.
- PostgreSQL `EXPLAIN (ANALYSE)` of a write is classified and gated like the write instead of as a read.
- The `query_to_xml` family, `crosstab`, `pg_notify`, `pg_logical_*`, `pg_replication_*`, `pg_stat_reset*`, `pg_ls_*` and more large-object functions are administrative, so agents are denied and read-only connections refuse them.
- A constant-true predicate (`WHERE true`, `WHERE 1`, `WHERE 1=1`, `WHERE 2 > 1`, `WHERE id = 1 OR true`) counts as unscoped DML. Predicates that depend on a column (`WHERE id = id`) are not evaluated and stay scoped.
- Grid headers and Go to Referenced Row now pick up foreign keys that arrive after the first draw; before, the redraw reused the old headers and menu.
- Go to Referenced Row on a column that belongs to several foreign keys offers the usable ones even when another key has a NULL value.
- Picking a PostgreSQL enum label no longer fails when the enum's type name looks like a built-in type such as `date_format` or `timestamp_source`.
- Opening a second table over a preview tab, dropping a table with open tabs and promoting a new structure tab now remove the old tab page instead of leaving it on screen without its controller, which aborted the app when clicked.
- A query stopped by a timeout now says "Query exceeded the Ns query timeout." instead of claiming the timeout was configured in Preferences, which was wrong for a per-connection timeout.
- Closing an editor tab no longer leaves it on screen stuck on "Rolling back and closing session…", including after choosing Save for a file tab; the stale tab used to abort the app when Split was clicked.
- Screen readers announce the selected-row count on the selection summary.
- Browse grid headers now show the primary key marker, and the foreign key marker and Go to Referenced Row appear even when the foreign keys arrive after the first draw.
- Reopening query history refreshes the list so queries run while it was closed appear immediately.
- PostgreSQL connections accept a bracketed IPv6 host such as `[::1]`.
- A PostgreSQL login the server refuses (wrong password or missing database) is reported at once instead of being retried, and a pooler in transaction mode gets an explanatory hint on prepared-statement errors.
- CSV imports can map explicit auto-increment values on PostgreSQL, MySQL/MariaDB and SQLite while generated columns remain excluded.
- Grid edits and spreadsheet paste preserve line breaks inside text values.

- MySQL and MariaDB connections with TLS Disabled no longer use a saved client certificate or key
- The window opens without waiting for old query history to be pruned at startup
- Undoing or redoing one of several edits to the same cell keeps the earlier edit pending against the value stored in the database, so saving no longer drops it or reports a changed row
- A table's column and foreign key lists from a superseded refresh are no longer applied after a newer refresh started
- Returning to a table after a Structure rename refreshes its browse columns before fetching rows, so exports use the current column names.
- Saving the window layout no longer waits for a slow disk read at startup, so the window stays responsive while saved tabs load
- Pressing Cancel while a connection is finishing no longer opens that connection anyway
- Refreshing, closing or pressing Kill twice in the activity dialog no longer cancels a Kill that is already running, so its result is always shown
- A run that cannot start (the session is closing or the connection is gone) no longer hides the result of the query still running in that editor
- Deleting or pinning several history entries in quick succession no longer brings a deleted entry back into the list
- Refreshing the table list and the editor's column suggestions now cancel the previous request at the database instead of letting it run on after a newer one or a connection change
- Editing a number so that only its stored form changes (`1.5` to `1.50`, `0` to `-0`) is now saved instead of being dropped as no change
- Copy Value preserves full text and JSON values, including previewed, pending and draft values; binary cells currently copy a byte-count label only ([#1587](https://github.com/cozyGarage/BookiE/issues/1587)). Editing literal `<NULL>` text no longer turns it into an empty value.
- MongoDB connections now reject malformed or URI-shaped host input before constructing the connection URI.
- Closing a table tab, paging, or disconnecting now stops the slow read it started on the server instead of letting it run to the timeout.
- PostgreSQL optimistic grid edits cast both new and previously read custom enum, enum-array, and domain values to qualified native types, so stale-row comparisons work across those columns.
- A PostgreSQL query that returns more rows than the result cap now returns the capped rows promptly and stops the server query, instead of waiting for the server to finish or timing out.
- Rebuilding the connection list no longer triggers GTK errors that could abort the app.
- Saving an edited cell or deleting a row in a PostgreSQL, MySQL, SQL Server, SQLite or DuckDB table no longer asks for a manual write approval every time; the write is already limited to one row per statement.
- MongoDB stale grid deletes now compare the document's full top-level field set as well as materialized values, so a field added after the read prevents deleting that changed document.


- Right-clicking an editable result cell opened the cell editor's own menu on top of the grid menu; only the grid menu opens now.
- PostgreSQL enum-array XLSX exports preserve two-dimensional values and non-default lower bounds as text through LibreOffice Calc and Gnumeric re-saves, including empty labels, literal `NULL`, SQL NULL elements and formula-shaped labels.
- MySQL query results keep their projected column metadata when no rows match, including inside transactions, and transaction queries obey the shared result cap.
- MySQL multi-statement saves refuse non-DML statements before dispatch and distinguish rollback failure; successful rollback requests no longer imply that non-transactional table writes were reversed.
- SQL Server rowversion and temporal period columns are read-only and omitted from generated INSERT statements, so copying or inserting rows does not try to overwrite server-owned values.
- CSV imports accept the `\x` hexadecimal blob format written by exports, preserving empty blobs and NULL separately.
- Malformed DuckDB script tails fail closed instead of executing a valid prefix and silently ignoring the remainder.
- DuckDB SQL literals preserve exact `rust_decimal` values with explicit precision and scale casts, including the crate's mantissa and scale limits.
- Formula-safe decimal CSV imports reject excess precision instead of rounding it.
- CSV imports preserve ClickHouse `Int128` and `UInt128` values exactly, including values prefixed by formula-safe apostrophes, instead of rejecting them as i64.
- Editing PostgreSQL array cells now casts their text value to the matching built-in array type instead of failing with a type mismatch.
- MongoDB browse pages scan field types with the same cursor used for page rows and keep conflicting BSON values read-only.
- MySQL pooled connections use UTC for `TIMESTAMP` decoding; dedicated sessions refuse non-UTC `TIMESTAMP` values instead of presenting a wrong instant.
- SQL Server `money` and `smallmoney` results are refused as undecodable instead of exposing the TDS client's rounded float conversion.
- SQL Server legacy `datetime` values decode only when their 1/300-second ticks map exactly to nanoseconds; inexact ticks remain undecodable.
- Cancelling a connection attempt over the system OpenSSH client now stops its ssh master process and cleans up its private directory, instead of leaving it running in the background.
- If the app is killed or crashes while using the system OpenSSH client, its ssh master process now exits with it instead of continuing to run in the background until the next launch.
- The "Saving in progress" dialog shown while closing a window now closes when the save ends, instead of staying open if the save failed.
- The structure editor now refuses column names that differ only in case on databases that ignore case, and refuses duplicate index names, before sending the change to the server.
- The filter bar now offers comparison operators for MySQL `MEDIUMINT` and PostgreSQL `time without time zone` columns instead of text matching.
- SQL completion now finds the statement under the cursor correctly when a comment or a PostgreSQL `$$` body contains a semicolon.
- A database driver that crashes while a write's size is being estimated, or while a session closes, now produces an error and a connection replacement instead of leaving the window waiting.
- MCP `export_data` with CSV now reports `truncated` when the row cap cut the result, as the JSON format already did.
- An MCP write preview that is cancelled or times out while its transaction is starting now says the outcome is unknown, instead of reporting a plain cancellation.
- Query history is left untouched and switched off, instead of being opened as if it were current, when its file was written by a newer version of the app.
- Saving a favorite or editing saved queries while the favorites list is still loading can no longer bring back an older list.
- Duplicating a connection while the keyring cannot be read now offers to enter a password for the copy, instead of assuming the original had none.
- Closing the Explain window now stops its query instead of letting it run until the query timeout.
- SQL Server queries that return several result sets now show every set inside an editor session or transaction, masked and audited like the first, instead of only the first.
- A MySQL or MariaDB connection that carries a PostgreSQL-style socket directory is now refused when it connects, instead of being checked against a PostgreSQL socket file.
- The connection form's Environment and Method choices can now be operated with a screen reader and other assistive tools.
- After a transaction start is interrupted with an unknown outcome (for example an MCP write preview that times out), the connection stops accepting governed writes until it is replaced, instead of carrying on as if nothing had happened.
- PostgreSQL column completion now tells apart a quoted mixed-case table such as "Users" from users, and keeps dots and doubled quotes inside quoted names.
- Browsing or querying a MongoDB collection no longer holds a whole sample of documents in memory while it works out the column types, which could exhaust memory on collections with very large documents.
- Pasting several columns into the grid now follows the order you see, skipping hidden columns, instead of the table's own column order; pasting from a hidden column is refused.
- Browse filters Contains, Starts with and Ends with now match a literal % or _ typed in the search on SQLite, DuckDB and SQL Server, and a typed [ on SQL Server, instead of treating them as wildcards or returning wrong rows.
- The SQLite table list now shows user tables whose names start with sqlite followed by another character, such as sqlite3_results.
- The grid's Set to NULL action now refuses read-only cells and columns that do not accept NULL, with a message, instead of staging a change that would fail on save.
- SQLite databases whose file names contain a question mark or a percent sign now open that exact file instead of a different one.
- Driver panics during connection capability or session health checks no longer escape PolicyGuard; the affected connection is reported unusable for replacement.

### Security

- Update TLS certificate verification and bundled trust roots to block distrusted emSign certificate chains.

- A masked agent whose ClickHouse, Redis or MongoDB batch failed partway saw the database's own error text; it now gets the same withheld message as other failures.
- A Redis `SELECT n` was treated as a read, so read-only connections and agent read access let it switch the shared connection to another database; it now needs the approval an unrecognised statement needs.
- A `FOR UPDATE` or `FOR SHARE` read inside a WHERE or HAVING subquery, a join condition or a function argument is now treated as a locking read, so read-only connections and agent read access refuse it.
- A host key listed as `@revoked` in known_hosts with a wildcard or negated host pattern, such as `@revoked * ssh-ed25519 …`, is now refused instead of being ignored.
- Unknown host keys on configured SSH jump hosts now require explicit confirmation before connecting.
- Statements that set a password, an encryption key or a connection secret, and text that does not end its strings or comments, are no longer saved in the query history.
- An agent's write preview on MySQL no longer runs DDL or other statements that MySQL commits immediately; they are refused inside a transaction instead of being applied and reported as rolled back.
- SQL Server `BEGIN TRAN`, `COMMIT TRAN` and `ROLLBACK TRAN` are now treated as transaction control, so a shared connection refuses them and a session tracks the transaction they open instead of auditing later writes as committed.
- Agent result masking now treats `to_json` / `to_jsonb` and JSON object builders the same as `row_to_json` when deciding which columns to redact.
- Agent result masking now redacts columns whose projection source cannot be resolved, and masks whole-row wildcard arguments instead of leaving them clear.
- A session or governed-write lockdown refusal is now recorded in the audit journal instead of ending without a terminal audit state.
- `SELECT … INTO` is now treated as a write, so read-only connections and agent read access refuse it instead of letting it create a table.
- The row-count estimate that guards large writes no longer runs a side-effecting function in your WHERE clause before you approve the statement; such statements ask for approval without an estimate.
- A session now refuses a script that hides BEGIN, COMMIT or ROLLBACK among other statements, so the transaction BookiE tracks always matches the one on the server.
- A SQLite, PostgreSQL, MySQL or MariaDB connection marked read-only is now read-only in the database engine itself, so a statement the safety checks mistake for a read still cannot change data; a read-only SQLite connection no longer creates a missing file.
- Importing a connection bundle now refuses a file over 16 MiB, or anything that is not a regular file, before reading it.
- Panic diagnostics retain source locations and requested backtraces while always withholding the panic message, including with `TABLEPRO_DEBUG_PANICS=1`.
- SSH connections refuse a host key marked revoked in `known_hosts` and ignore a relative configuration directory.
- Agent token files are created with owner-only permissions, and approval prompts strip bidirectional text controls that could disguise displayed text.
- Shortened agent-token labels stop at character boundaries and never split a UTF-8 character.
- Bulk import approval is bound to the requested target, and read-only sessions refuse `BEGIN READ WRITE`.
- Controlled batch approval interruptions receive a terminal audit outcome.
- Known transaction errors no longer erase prior successful write effects from the audit record.
- Agent masking covers PostgreSQL XML serialization results and redacts driver errors that could contain masked values.
- Administrative PostgreSQL function matching respects qualified names.
- Constant numeric predicates are evaluated exactly when checking whether a write is scoped.
- The built-in SSH client is updated to a release that fixes recent upstream security advisories.

## [0.1.5] - 2026-09-27
- Choosing the system OpenSSH client inside the Flatpak build now stops immediately with a message to use the built-in SSH client.
- The Debian package now includes the SSH password helper that the system OpenSSH client needs.
- A lost connection stops reconnecting when the password, TLS setting or configuration is wrong and says why, instead of retrying forever.
- SQL completion no longer mixes up the columns of tables that share a name in different schemas.
- In the headless agent, a write interrupted on one connection no longer blocks governed writes on every other connection until restart.
- The headless agent now replaces a cached connection after a driver panic or an unusable-connection fault instead of reusing it because its health check still answers.

### Added
- Loaded results can be exported as Markdown, HTML, XML, SQL INSERT statements, or an Excel workbook, alongside CSV and JSON. Statement export is offered only for connections whose engine can express SQL literals, and an Excel export exceeding worksheet limits leaves any existing destination untouched. Workbooks preserve fractional seconds, timezone-bearing timestamps and dates outside 1900–9999 as exact text; ordinary supported dates and whole-second times remain native spreadsheet cells. Empty text is refused with CSV/JSON alternatives instead of being silently collapsed into NULL, preserving any existing destination. XML and HTML preserve carriage returns when parsed. XML refuses unsupported XML 1.0 characters and HTML refuses NUL characters with a row/column error instead of replacing or dropping them.
- Saved queries have a management dialog (Ctrl+Shift+D): search them, open one in a new editor tab, rename it, or delete it. Until now a saved query could only be reached through the quick switcher and could not be removed.
- A query that runs for 10 seconds or longer shows a desktop notification when it finishes while the window is not focused.
- Ctrl+O opens a .sql file in a new editor tab. A file larger than the editor's limit is refused with an explanation instead of being cut short.
- An editor tab opened from a .sql file is titled by the file, marked while it has unsaved changes, and saves back to it with Ctrl+S; Ctrl+Shift+S saves to a new file, and Ctrl+S on an unsaved query asks where to save it. If another program changed or removed the file since it was opened, the save stops and offers Overwrite or Save As instead of replacing the other program's changes. Closing a tab with unsaved file changes asks first, and after a restart the tab is linked to its file again; if the file is gone, the tab keeps its text and says it is no longer linked.
- Query history now also records the statements the app itself runs when you save a table structure change or save edited rows, and the history dialog can filter by where a statement came from.
- Logs can be written as structured JSON lines by setting the log format environment variable, for collection by a log agent. Any other value keeps the human-readable format.
- A CSV file can be loaded into an existing table from the table's context menu. The file's separator and header row are detected and can be changed, each table column is mapped to a field before anything runs, and the whole import is approved once. It commits in bounded batches, shows progress, can be cancelled, and reports how many rows were written when it stops early.
- A CSV file can also create the table it is loaded into, from the schema header in the sidebar. The column names and a type guessed from the first rows of the file are shown for every column and can be changed before the table is created. A guess falls back to text whenever any value in the sample does not fit a narrower type.
- The structure editor shows a Comment field for each column, and reads each column's comment on PostgreSQL, MySQL, SQL Server and ClickHouse, and writes it when creating a table, adding a column or editing one. SQLite refuses a comment with a clear message instead of dropping it silently.
- Open Quickly (Ctrl+P) lists the connection's tables and views across every schema. Typing a name or a schema-qualified name such as `sales.orders` finds them, and choosing one opens it.
- A browsed table's cell menu has Filter by This Value, which narrows the table to rows holding that value, or to rows where the column is NULL for an empty cell. It replaces an existing rule on the same column and keeps the others.
- PostgreSQL sessions opened by the app report the application name BookiE, and those opened for agents report BookiE agent, so they can be told apart in `pg_stat_activity`.
- PostgreSQL materialized views are listed with views in the sidebar and open read-only.
- The built-in SSH client can authenticate with keys held by ssh-agent, chosen as "SSH agent" in the SSH section, including in the Flatpak build; a missing agent or an agent with no keys is reported plainly.
- An SSH tunnel can use the system OpenSSH client instead of the built-in one, so `~/.ssh/config`, ProxyJump, ssh-agent and host certificates apply. Host keys are always checked: the app asks before trusting a new host even if `~/.ssh/config` would accept it, and the agent daemon refuses an unknown host. A saved password or passphrase is only given to the host or key it belongs to, never to a jump host. Not available in the Flatpak build, which cannot run the host's ssh.
- An editor tab can turn on Session to run on its own PostgreSQL, MySQL, SQL Server or SQLite file connection, so settings, temporary tables and a transaction started with BEGIN carry over between runs. The button shows when a transaction is open, and turning Session off or closing the tab with one open asks whether to commit or roll back. Every statement still goes through policy, approval and the audit journal, and COMMIT and ROLLBACK are recorded as transaction outcomes.
- A Catalog window in the main menu lists a PostgreSQL connection's functions and procedures, triggers, sequences, extensions, roles, user-defined types and each table's privileges by role, optionally within one schema. An engine without catalog support, a listing refused by policy, a failed listing and an empty one each say so differently.
- Agents can list a PostgreSQL connection's routines, triggers, sequences, extensions, roles, user-defined types and table privileges through the new `list_objects` MCP tool, optionally within one schema. It needs only a read token, is limited to the token's allowed connections, and is audited like other catalog reads; an engine without catalog support answers that the listing is unsupported rather than returning an empty list.
- A saved connection can have its own connect timeout and query timeout, set when it is created. The connect timeout also applies to agent connections; 0 keeps the defaults.
- A saved connection can be given a name; leaving the name blank keeps the address-derived label.
- A saved connection can be duplicated; the copy starts without saved credentials.
- A saved connection can carry a colour tag from a fixed palette, shown beside it in the connection list.
- The connection list is split into a section per group, with ungrouped connections in their own section.
- Saved connections can be exported to and imported from a connection bundle file. A bundle without a passphrase carries no credentials, a passphrase-protected bundle encrypts them, and an import shows every connection and what will happen to it before anything is written.

### Changed

- The built-in SSH client's unknown-host-key error no longer suggests connecting once with the system `ssh` command, which writes to a different `known_hosts` file than the one this client reads.
- A built-in SSH host-key prompt now waits until its button response is handled before treating a close attempt as a decline, so trusting a host persists the key.
- The built-in SSH client reports plainly when a server accepts only keyboard-interactive authentication, which it does not support, instead of a generic authentication failure.
- The built-in SSH client now sends keepalives and can report a tunnel as closed once a bastion stops responding, instead of leaving a dead tunnel looking alive until a database driver's own timeout notices.
- When a saved password can't be read because no keyring is running, the keyring is locked, or its unlock prompt was cancelled, the connection error now says which one and what to do, instead of showing the raw D-Bus error.
- The keyboard-shortcuts dialog and date editor now use the GNOME 50 APIs.
- Development builds isolate connections, history, audit, drafts, settings, the policy file, locks, and keyring items from installed builds.
- Column-width and filter persistence is owned by the application and shared explicitly with its windows and tabs.
- Query history is owned by the application and passed explicitly to editors, dialogs, preferences, and retention work.
- Workspace cache, coalesced writer, and close-time flush are owned by the application and shared explicitly across windows. A connection whose editor draft cannot be read no longer blocks restoring every other open connection's tabs, and deleting a saved connection now removes its drafts from disk instead of leaving them behind.
- Database connections, user preferences, and the MCP agent bridge are owned by the application and shared explicitly with its windows and dialogs.

### Fixed

- SQL Server `DECIMAL(38,38)` values no longer panic the driver and retain exact text when they exceed the editable decimal range.
- SQL Server `sql_variant` values keep their native column type and show as undecodable instead of being mislabeled as a base scalar.
- Browse shortcuts for Left, Right, and space showed keypad keys, and click shortcuts showed Shift and Ctrl alone.
- New connection opened on the first driver with port 5432, database postgres, and username postgres.
- Browse shortcuts for Left, Right, and space showed a blank key.
- Click shortcuts were labeled Pointer_Button1.
- Test and Connect sat at opposite ends of the connection header, and a long title ran into the buttons.
- A ClickHouse connection with Verify CA or Verify Full through an SSH tunnel checked the certificate against the tunnel's local address instead of the database's own hostname, so both modes always failed. They now verify against the database's hostname.
- A MongoDB connection with Verify CA or Verify Full through an SSH tunnel checked the certificate against the tunnel's local address instead of the database's own hostname, so both modes always failed. They now verify against the database's hostname.
- A Redis connection with Verify CA or Verify Full through an SSH tunnel checked the certificate against the tunnel's local address instead of the database's own hostname, so both modes always failed. They now verify against the database's hostname.
- A session whose connection was lost now refuses any further statement instead of dispatching it and letting the resulting error turn off governed writes for every connection.
- Stopping the MCP agent server while a write was still in progress could tear down the server before that write reached a recorded outcome, leaving its audit entry open. The server now waits at least as long as a write is allowed to run before it finishes shutting down, so an interrupted write is always recorded as cancelled or unknown.
- A session that loses its connection mid-transaction now has its transaction outcome recorded as uncertain, and the session itself stops accepting statements even if the driver still reports it usable.
- A session COMMIT with no preceding BEGIN, and a BEGIN sent while a session transaction is already open, are now refused instead of being sent to the database unaudited.
- A session COMMIT that only succeeded because PostgreSQL had already rolled back an aborted transaction is now audited as rolled back instead of committed.
- A cancelled or timed-out session COMMIT or ROLLBACK is now audited with a cancelled or timed-out outcome instead of a generic failure.
- A session COMMIT that fails because the database already ended the transaction, such as a deferred foreign key violation, no longer leaves the session's transaction marked open.
- MongoDB nested documents, arrays and uncommon top-level BSON kinds retain their BSON markers as canonical Extended JSON instead of debug text. Nested documents and arrays plus top-level BSON Timestamp, regex and MinKey cells can be edited in the grid and write back as native BSON; canonical Extended JSON imports reconstruct nested Decimal128, date and binary subtypes. Real-server JSON, CSV and XLSX exports and the MCP browse tool preserve those markers.
- CSV imports into SQLite INTEGER, REAL and NUMERIC affinity columns pass unparseable values as text, allowing SQLite to store them without rejecting valid mixed storage classes.
- Duplicate Row refuses rows with undecodable cells or a mismatched cell count instead of inserting a silently substituted NULL.
- ClickHouse rejects response rows whose value count does not match the column metadata instead of padding or truncating the row.
- A driver that reports its connection as disconnected now triggers an immediate reconnect attempt instead of waiting up to 30 seconds for the next scheduled connection check.
- SQL Server decimals wider than the editable range keep their sign and digits. A negative value no longer shows a minus sign inside its fraction, and a whole number no longer gains a trailing ".0".
- MySQL zero dates such as 0000-00-00 are shown as their stored text instead of an empty cell. Negative TIME values keep their sign, times outside one day and dates with zero parts are shown exactly instead of as undecodable, and YEAR values appear as numbers. All of them can be written back through edits, parameters and SQL exports.
- DuckDB dates, times, timestamps and enum labels decode as usable values instead of debug strings. Temporal precision, timezone instants, infinities and end-of-day times survive parameter and SQL round trips; unsupported intervals, collections and calendar ranges remain visibly undecodable and cannot be written back.

- PostgreSQL intervals retain independently signed fields under every interval style, and extreme durations use a re-importable seconds representation. Date and timestamp infinities remain distinct from NULL.

- PostgreSQL arrays of common scalar and temporal types preserve NULL elements, empty values, nesting, lower bounds and exact numeric digits through query results and SQL exports. int2vector and oidvector values keep their space-separated form. Unsupported element types and oversized decoded arrays remain visibly undecodable.

- PostgreSQL end-of-day times remain 24:00:00 instead of silently becoming midnight, and times with time zones retain their stored offsets and microseconds through queries and SQL exports.

- PostgreSQL SQL exports preserve BC dates and years above 9999 using valid era and year syntax, including fractional timestamps and UTC instants.

- PostgreSQL numeric results preserve wide integers, long fractions, decimal scale, NaN and infinities. Values beyond the editable decimal range remain exact text instead of appearing undecodable.

- Excel exports preserve integers beyond 15 digits and all exact decimals as text cells, retaining every digit and decimal scale. These cells require explicit numeric conversion for spreadsheet arithmetic.

- Numeric input in grid edits, filters and CSV imports rejects overflow to infinity and nonzero underflow to zero. Named decimal parameters stay exact, SQLite still compares them as numbers, and automatic parameter typing keeps values as text when they exceed the exact decimal range.
- SQL copy and export use scientific float literals to avoid tiny values becoming zero or overflowing an engine's decimal parser; ClickHouse decimal literals retain their full precision.
- Redis commands preserve empty quoted arguments instead of dropping them.
- DuckDB accepts bound parameters in result queries instead of reporting the operation as unimplemented. Decimal parameters and results stay exact numbers, so arithmetic on a bound decimal is no longer rounded to a whole number. DATE and microsecond TIME/TIMESTAMP parameters bind natively. Finer-than-microsecond TIME/TIMESTAMP and all TIMESTAMPTZ parameters remain exact text and may need an explicit cast for expressions.
- MySQL and ClickHouse decimals retain their exact digits, including values beyond the editable decimal range. Grid edits and filters reject decimals that would need rounding.
- ClickHouse non-finite numbers remain distinct from NULL, and JSON exports and agent responses retain NaN and infinity as text instead of substituting NULL.
- SQL Server INSERT exports preserve Unicode text and render booleans as valid numeric literals.
- App shutdown now cancels MCP operations and waits for its owned HTTP server before flushing persistence.
- Preferences migration persists its completion marker across fresh handles, preserves malformed legacy files, and rolls back a settings update if its rollback JSON mirror cannot be written.
- Repeated CSV headers at the maximum identifier length retain a unique suffix instead of looping during column inference.

- Editing a long text or JSON cell in the grid now starts from its full value instead of the shortened text shown for display, so a small edit no longer truncates the rest of the value.
- The server activity view shows a binary value as its byte count instead of a label that read like a hexadecimal escape.
- The structure editor shows a column default as the SQL that defines it, so an empty-string default no longer reads as no default, and a MySQL column edit no longer drops an empty-string default or fails on a text default.
- On X11 the app's windows now group under its launcher in docks and task switchers, whichever command started it.
- Changing a PostgreSQL column's type in the structure editor keeps the column's own collation instead of resetting it to the type default, and a MySQL column edit keeps its collation instead of taking the table default.
- A database driver that stops unexpectedly is reported as a failed operation, with writes marked as having an unknown result, instead of leaving the request waiting forever. The connection is then replaced rather than reused.
- Embedded application icons now use the same BookiE artwork as installed packages.
- Malformed MongoDB SCRAM nonces are rejected instead of crashing authentication.
- SSH key and TLS certificate reads remain bounded if a file changes while it is read.
- SSH socket forwarding falls back to a short private path when the runtime directory would exceed Unix limits.
- ClickHouse connection timeouts no longer misreport a certificate hostname mismatch.
- MongoDB server-selection failures (for example, an unreachable host) no longer misreport a certificate hostname mismatch.
- A SQL Server script now keeps running the next `GO` batch after one batch fails, instead of stopping the whole script.
- PostgreSQL indexes built on an expression now appear in the structure tab with the expression as their key, a partial index shows its WHERE condition, and INCLUDE columns are no longer listed as index keys.
- SQLite foreign keys that reference the parent table without naming its columns now show the parent's primary key columns instead of blanks.
- SQLite foreign keys, indexes and columns read right after a structure change are no longer missing when the read lands on another pooled connection.
- A SQL Server batch that raises an error after its first result set now reports the error instead of showing the first result as a success.
- A SQL Server result cut at the row limit now waits for the rest of the batch to finish, instead of leaving it running on the server with its locks held until the next query.
- MongoDB accepts `DROP TABLE people` as well as the quoted form, instead of reporting the statement as unsupported.
- Renaming a column and changing nothing else now saves. On SQLite the whole save was refused, and on MySQL the column definition was restated without its collation, character set or comment.
- MySQL and SQL Server values that the driver cannot decode now show as undecodable instead of as an empty cell. Such a cell stays read-only, and a row whose key could not be read is refused rather than updated or deleted silently.
- A PostgreSQL result with one undecodable value (for example, a NUMERIC too wide to represent) shows that cell as undecodable, logs the column so the cause can be traced, and keeps the rest of the row and result instead of failing the whole query. An undecodable cell stays read-only, and a row whose key could not be read is refused instead of being changed or deleted silently.
- Redis binary values with invalid UTF-8 retain their original bytes. SQL statement export preserves binary values using exact literals on PostgreSQL, MySQL, SQLite, SQL Server, ClickHouse and DuckDB; unsupported binary exports, undecodable values and non-finite numbers are refused instead of substituting NULL. Copy as IN continues to skip binary and undecodable cells.
- CSV export and Copy as CSV write empty text as a quoted empty field and NULL as a bare empty field, so the two stay distinct. With quoting set to Always, NULL was also written as a quoted empty field.
- SQL Server INSERT statements copied or exported from a `datetime` column with milliseconds now run and restore the same value. SQL Server rejected them with a conversion error.
- ClickHouse decimals keep their declared scale, so 2.50 in a Decimal(10, 2) column no longer shows as 2.5.
- ClickHouse timestamp parameters keep their fractional seconds. Local timestamps lost every fraction and timezone timestamps were cut to milliseconds.
- ClickHouse SQL INSERT exports of timezone timestamps now run and keep every fractional digit. ClickHouse rejected them with a parse error.
- ClickHouse `DateTime64(9)` parameters and SQL exports outside its exact nanosecond range are refused locally instead of reaching an engine range failure or conversion.
- ClickHouse `DateTime` and `DateTime64` results with named IANA timezones now preserve their instant. Ambiguous or nonexistent local clock values are shown as undecodable rather than guessed.
- SQL Server `datetimeoffset` values keep their stored instant, original offset and all seven fractional digits in the grid, in edits and in copied or exported INSERT statements. A non-UTC value was shifted by its offset a second time, and every value was converted to UTC.
- MySQL and MariaDB INSERT statements copied or exported from text or JSON holding a backslash or NUL character now restore the same value when the server runs with `NO_BACKSLASH_ESCAPES`. Each backslash was doubled, or the statement was rejected.
- MySQL column-comment DDL refuses comments containing backslashes until it can execute with a known session SQL mode, rather than silently storing a different comment.
- MySQL `BIT` columns show their numeric value, supported widths can be edited within range, and spatial columns show their stored geometry bytes as read-only values; copied or exported INSERT statements restore the same data. These columns were shown as empty or unreadable cells, or could not be edited safely.

### Security

- Unparseable statements require approval when write or DDL approval is enabled, even when unparseable SQL is otherwise allowed.
- Statements that access host files or run external programs, writes with unknown effects, and Local `TRUNCATE` require human approval.
- The agent daemon no longer trusts an SSH host key it has not seen before. An unattended connection to an unknown host fails and names the key's fingerprint; connecting once from the app or with `ssh` records it. A changed key is still refused everywhere.
- A lone BEGIN, COMMIT or ROLLBACK on a shared connection is refused with an explanation, in the SQL editor and through MCP. Each statement ran on a shared connection, so a script such as `BEGIN; UPDATE …; ROLLBACK;` committed the update while reporting every step as successful. A whole transaction sent as one batch, such as a SQL Server `GO` batch, still runs.
- A saved connection's SSH jump chain is capped at eight hops, so an edited connection file cannot force a deep recursive parse.

## [0.1.4] - 2026-09-17

### Changed

- Isolated GTK and Secret Service tests through shared local/CI runners.
- Arch and Debian packages: system SQLite, Rust 1.98, and `bookie` launchers with `tablepro` aliases.

### Fixed

- SQL formatting dropping significant whitespace and literal prefixes.
- BOOLEAN cells with mismatched bytes/text entering the inline editor.
- PostgreSQL INTERVAL overflow and malformed INET/CIDR prefixes treated as NULL.
- DuckDB identifier quoting and Redis read-only SELECT in the manual connection lab.
- Debian fallback package installing `tablepro` while the desktop file launched `bookie`.
- ClickHouse VerifyFull reporting a hostname mismatch as a dropped connection.
- MongoDB VerifyFull reporting an IP-endpoint identity mismatch as connection refused.
- Redis VerifyFull reporting an IP-endpoint identity mismatch as connection refused.

### Security

- Agentd session reuse after Secret Service or SSH/CA file rotation.
- Unbounded PostgreSQL and MongoDB SCRAM iteration counts.

[Unreleased]: https://github.com/cozyGarage/BookiE/compare/linux-v0.2.0...linux
[0.1.5]: https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.1.5
[0.2.0]: https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.2.0
