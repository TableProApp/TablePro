# Changelog: TablePro Linux

## [Unreleased]

### Added
- PostgreSQL TLS verification now trusts the operating system certificate store when no custom authority is configured.
- MongoDB table browsing now seeks deep pages in `_id` sort order, including collections with mixed key types.
- MongoDB offset and `_id` keyset pages apply equality, inequality, comparison, range, set-membership, null, `LIKE` and `ILIKE` filters with SQL null behavior.
- Saved SSH hops now have stable IDs and credential revisions, with separate Secret Service operations for per-hop passwords and key passphrases. Legacy connections-file v1 data loads and migrates to v2 on save; jump-chain editing and per-hop transport use remain disabled until their integration lands.
- Encrypted connection bundles now write format version 2 with each versioned SSH hop's password or key passphrase; version 1 imports remain supported and plaintext bundles still contain no credentials.
- MongoDB browse long text, binary and structured values use guarded, ObjectId-safe `_id` refetches for full values.
- Redis string values now use guarded, byte-safe key refetches for full values; collection and container debug strings remain untruncated.
- SQL-backed table browse cells over 8 KiB now show a typed preview with the original byte count; View Value refetches through the guarded connection by primary key.
- Arbitrary SQL result grids now preview long text, JSON and binary cells with byte counts; View Value reads the complete value from the guarded result already in memory.
- Previewed grid cells no longer keep a second full value in each cell widget.
- Materialized result-grid rows share their source values, reducing duplicate memory for long cells while preserving pending edits on replacement.
- Overlapping View Value requests discard stale replies so an older fetch cannot replace the latest requested cell.
- ClickHouse long text refetch now has a guarded 12,000-byte contract with composite-key and native-value checks.
- DuckDB BLOB values now have guarded exact-refetch coverage against an embedded database and native storage oracle.
- MySQL and MariaDB CHAR results now have `PAD_CHAR_TO_FULL_LENGTH` coverage for padding, VARCHAR, empty values and NULL.
- MySQL and MariaDB CSV imports preserve impossible calendar dates accepted by `ALLOW_INVALID_DATES`.
- PostgreSQL CSV imports preserve native BC date, timestamp and timestamptz values.
- The sidebar groups tables and views under schemas and groups with object counts; a click collapses a group, a search expands the groups that match, and the choice is remembered per connection.
- A Pin results button in the SQL editor keeps the current results above the results of the next run, and unpins them again.
- Each statement of a script gets a gutter mark after a run: a tick for a statement that returned, a cross for one that failed.
- MySQL ENUM/SET grid parsing now tests malformed metadata refusal and escaped
  labels, using real MySQL column metadata and native ordinal/byte oracles.
- A failed PostgreSQL statement in the SQL editor shows the line and column of the error.
- A failed statement in the SQL editor offers a Copy error button.
- Selecting several rows shows each numeric column's sum and average in the selection badge tooltip, with NULLs skipped.
- A connection's colour tag now also paints a strip above its workspace tabs, so a window shows which connection it belongs to.
- PostgreSQL's six built-in scalar range types now have native text/JSON/wire refusal checks; empty ranges remain distinct from SQL NULL, and refused literals and bindings preserve target and sibling rows.
- MongoDB and Redis unfiltered, unsorted table pages now use native fetches even when metadata finds a primary key; a native MongoDB GTK scenario checks cursor values remain visible until refresh and an approved post-refresh edit preserves sibling fields.
- Result column headers show the column type and mark primary-key and foreign-key columns.
- Redis 0.2.0 support remains scoped to a single host/port endpoint; Sentinel and Cluster topologies are explicitly deferred.
- Redis key browsing preserves arbitrary-byte keys and non-UTF-8 string values, and fills requested pages across partial SCAN batches; Docker contracts check native Redis oracles.
- MongoDB nested null filters now compare JSON-filter and MQL results against native queries, distinguishing missing paths, explicit BSON null, and ordinary values.
- SQL Server query batches now preserve ordered result sets through the policy guard, editor, MCP query responses, and JSON export; MCP shares its row cap across sets, and CSV export refuses multi-set results rather than dropping data.
- ClickHouse Enum8/Enum16 values now cover signed endpoints and zero (`-128`, `0`, `127` for Enum8; `-32768`, `0`, `32767` for Enum16) through native casts, parameter writes, CSV import and SQL-literal replay; undeclared labels for both enum widths are refused without changing stored rows. Nullable Enum16 also preserves SQL NULL, the literal `NULL`, and labels through these consumers.
- ClickHouse Enum8/Enum16 consumers now distinguish an empty-string enum label from SQL NULL through native reads, parameter writes, CSV import and Copy as SQL replay; nullable Enum8 is included.
- ClickHouse `Array(Nullable(Enum8))` results now keep SQL NULL array elements distinct from the literal `NULL` enum label, with the native `toJSONString` result checked through JSON/CSV/XLSX exports and explicit write refusal.
- ClickHouse Map values now cover Enum8 apostrophe/Unicode/literal-`NULL` labels and nullable Enum16 empty/NULL distinctions through native JSON, JSON/CSV/XLSX exports, and explicit lossy-write refusal with stored-row preservation.
- PostgreSQL name[] typed CSV import now checks NULL/empty distinctions, escaped and Unicode labels, the 63-byte UTF-8 boundary, and exact native array wire preservation.
- PostgreSQL custom enum-array slicing now checks native lower-bound normalization, multidimensional shape, SQL NULL versus empty arrays, literal NULL/Unicode labels, and typed rebind wire equality.
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
- Holding Ctrl and pressing Tab repeatedly walks deeper through the recently used tabs; releasing Ctrl keeps the chosen tab.
- Preferences has an Editor font family setting; an empty value keeps the system monospace font.
- Table tabs can export every row of the table, or of the filtered and sorted view, to CSV or JSON in a background job with progress and cancel.
- PostgreSQL `bit[]` and `varbit[]` preserve values through results, typed parameters, CSV import, and keyed grid edits, including empty bit strings, SQL NULL, non-default bounds, and refusal of invalid edits without changing sibling rows.
- PostgreSQL `citext[]` preserves exact elements, SQL NULL, empty arrays, multidimensional shape, zero lower bounds and case-insensitive comparisons through results, typed parameters, keyed grid edits and CSV round-trips; malformed values are refused without changing target or sibling rows.
- PostgreSQL custom enum arrays preserve three-dimensional shape and the six-dimensional limit, non-default bounds, SQL NULL, empty and escaped labels through result decoding and typed parameter rebinding, with native type, JSON and wire-byte comparisons.
- PostgreSQL `bit[]` and `varbit[]` query results now preserve bit values through typed parameter and CSV re-import, including empty bit strings, SQL NULL, and non-default array bounds.
- The result grid's cell menu also opens with Shift+F10, and the editor find fields have accessible names.
- Result grids have a Columns… menu entry to hide and show columns; the choice is remembered per table and at least one column always stays visible.
- Table browse refreshes omit hidden non-key columns while retaining keys; full-row copy and current-page export refuse incomplete rows, while full-table export fetches complete pages.
- PostgreSQL `pg_lsn[]` preserves all 64 LSN bits and SQL NULL through results, inferred typed bindings, keyed updates and typed CSV import; native type/text/JSON/wire checks cover malformed-input refusal and sibling preservation.
- PostgreSQL `macaddr[]` preserves canonical six-octet values and SQL NULL through results, inferred typed bindings, keyed updates and typed CSV import; native type/text/JSON/wire checks cover malformed-input refusal and sibling preservation.
- PostgreSQL `macaddr8[]` preserves canonical eight-octet EUI-64 values and SQL NULL through results, inferred typed bindings, keyed updates and typed CSV import; native type/text/JSON/wire checks cover malformed-input refusal and sibling preservation.
- PostgreSQL `inet[]` and `cidr[]` preserve IPv4/IPv6 addresses, prefixes, SQL NULL and array bounds through results, inferred typed bindings, keyed updates and typed CSV import; invalid prefixes and non-network CIDR host bits are refused without changing target or sibling rows.
- PostgreSQL `xml[]` preserves XML fragments, SQL NULL, native array text and wire bytes through results, inferred bindings, keyed grid edits, typed CSV restore and JSON/CSV/XML/HTML/Markdown/XLSX/SQL file exports; malformed XML retains native `2200N` refusal without changing target or sibling rows.
- PostgreSQL custom enum identifiers preserve metadata, keyed edits, and typed filters when a mixed-case quoted schema/type collides with lowercase names earlier in session or transaction-local `search_path`; native catalog and shadow-row checks verify the selected type, and shadow-only labels retain native `22P02` refusal.
- PostgreSQL enum reads, bound value and SQL NULL filters, and bound enum updates work for a restricted role without enum `USAGE`; invalid labels retain native `22P02` refusal and sibling rows remain unchanged.
- PostgreSQL custom composite arrays and unlisted built-in `money[]` and `point[]` arrays report explicit unsupported results and refuse literal/bound writes without changing target or sibling rows.
- PostgreSQL custom enum metadata and keyed edits preserve schema and type identifiers at PostgreSQL's 63-byte catalog limit, including a multibyte UTF-8 character at the final type-name boundary.
- Result grids have View Value…, which opens the whole cell in a read-only window: pretty-printed JSON, a hex dump for binary data, and a Copy value button.
- A saved connection that is still connecting can be cancelled from the progress notice.
- Starting BookiE while it is already running now brings the existing window forward instead of exiting silently.
- The SQL editor has find and replace: Ctrl+F opens a search bar with next, previous, a match count, Replace and Replace All.
- The connection form starts on PostgreSQL, offers file pickers for SQLite and DuckDB files and for the TLS certificate authority, and a TLS failure now says to check the TLS setting.
- A failed connection from the saved list now offers Try Again and Edit Connection instead of only Close.
- Saved connections can be edited from the welcome list, including their password, TLS, timeouts and single-hop SSH settings.
- PostgreSQL enum results and browse filters preserve the literal label `NULL` separately from SQL NULL across scalar and array projections and typed comparisons.
- PostgreSQL UUID-domain arrays preserve their values through result decoding, bound writes, and keyed edits.
- PostgreSQL domains over arrays preserve declared type metadata and non-default bounds through results and keyed edits, with native JSON/wire checks and domain CHECK refusal.
- PostgreSQL CSV imports cast custom enum labels to their catalog type and refuse ambiguous blank enum cells unless an explicit NULL marker is set.
- PostgreSQL scalar enum CSV export and typed restore preserve leading and trailing label spaces.
- PostgreSQL grid edits preserve wide `NUMERIC` values that are stored as exact text.
- PostgreSQL enum parameter inference stays bound to a qualified target type after `SET ROLE` when a same-named shadow enum leads `search_path` and the target schema is absent; target-only values and native invalid-label refusal are covered.
- PostgreSQL enum parameter inference also stays bound to a qualified target when a login role's configured default `search_path` places a same-named shadow enum first and omits the target schema; target-only/NULL values and native invalid-label refusal are covered.
- PostgreSQL keyed enum edits and inferred query parameters stay bound to a mixed-case quoted target when a restricted role's `search_path` leads with a lowercase shadow and omits the target schema; shadow-only labels retain native `22P02` refusal.
- SQLite STRICT `ANY` results from `quote()` remain TEXT through CSV restore, preserving numeric, empty, Unicode, escaped-apostrophe, BLOB, formula-shaped and SQL NULL literal forms.
- SQLite `instr()` results over STRICT `ANY` preserve INTEGER versus SQL NULL and text, Unicode, and byte-oriented BLOB search positions through typed CSV restore.
- SQLite `length()` results over STRICT `ANY` preserve INTEGER versus SQL NULL through typed CSV restore, including Unicode character counts and BLOB byte counts with embedded NUL.
- SQLite attached-schema STRICT `ANY` results preserve INTEGER, REAL, TEXT, BLOB and SQL NULL storage classes through app-level typed CSV restore.
- SQLite JSON aggregates over STRICT `ANY` preserve `json_group_array()` null/empty semantics and `json_group_object()` duplicate-key, NULL-key omission, and NULL-value semantics through typed CSV; JSON export retains exact result strings, and XLSX keeps object aggregates in text cells.
- DuckDB `TIME_NS` and `TIMESTAMP_NS` preserve all nine fractional digits on parameterized INSERT and UPDATE, including SQL NULL and untouched sibling values.
- The editor find bar has Match case and Regular expression toggles.
- A Switch database button in the window header lists the databases the account can open on PostgreSQL, MySQL, SQL Server, ClickHouse and MongoDB, reconnects to the one you pick and remembers it for that saved connection.
- The Connect button in the connection form becomes Cancel while it is reaching the server, so a slow or unreachable host no longer has to be waited out.

### Changed
- A successful rollback request now warns that session state and other non-transactional side effects may remain after a failed save.
- Startup opens the query history database while the rest of the application starts instead of waiting for it first.
- The Debian package installs its programs without debug symbols, which makes the installed files about a quarter smaller
- The distro-floor image installs a pinned, checksum-verified `rustup-init` instead of piping an unverified script to the shell.
- The time shown for a statement no longer includes the wait for your approval on a guarded connection.
- MongoDB browse pages now use a bounded schema sample and stable `_id` paging instead of scanning the full collection for every page.
- Disposable database test fixtures use tmpfs and reduced flush syncing; lost-ack, crash and restart tests keep durable storage.

- Ctrl+Tab switches to the most recently used tab, and back again, instead of the next tab in the strip.
- Create table from CSV now explains that ClickHouse, MongoDB and Redis connections cannot do it, and DuckDB gets its own JSON type name.
- The app builds and runs its tests on Ubuntu 24.04 and Debian 13 (GTK 4.14, libadwaita 1.5 or newer); the shortcuts window uses the standard GTK layout.
- Large results use about 45% less memory in the grid because rows are built only when they scroll into view.
- Browse results share their in-memory query result; GTK row objects are created when the view requests them. This avoids eager per-row GObject creation but does not page database rows or bound result memory.
- Grid context-menu CSV copies encode SQL NULL with a collision-free marker, keeping it distinct from empty text and enum labels; formula sanitization remains enabled.
- CSV file and MCP exports show the null marker used for SQL NULL cells and choose one that does not collide with exported text values, so the matching import preserves empty text and marker-shaped labels. Turn off spreadsheet-safe text to round-trip formula-shaped values literally.
- Markdown table exports and copies quote text cells and escape table/inline markup, keeping text labels such as `NULL` distinct from SQL NULL.

### Fixed

- The window opens without waiting for old query history to be pruned at startup
- Undoing or redoing one of several edits to the same cell keeps the earlier edit pending against the value stored in the database, so saving no longer drops it or reports a changed row
- A table's column and foreign key lists from a superseded refresh are no longer applied after a newer refresh started
- Saving the window layout no longer waits for a slow disk read at startup, so the window stays responsive while saved tabs load
- Pressing Cancel while a connection is finishing no longer opens that connection anyway
- Refreshing, closing or pressing Kill twice in the activity dialog no longer cancels a Kill that is already running, so its result is always shown
- A run that cannot start (the session is closing or the connection is gone) no longer hides the result of the query still running in that editor
- Deleting or pinning several history entries in quick succession no longer brings a deleted entry back into the list
- Refreshing the table list and the editor's column suggestions now cancel the previous request at the database instead of letting it run on after a newer one or a connection change
- Editing a number so that only its stored form changes (`1.5` to `1.50`, `0` to `-0`) is now saved instead of being dropped as no change
- Copy Value preserves full previewed, pending and draft cell values; editing literal `<NULL>` text no longer turns it into an empty value.
- MongoDB connections now reject malformed or URI-shaped host input before constructing the connection URI.
- Closing a table tab, paging, or disconnecting now stops the slow read it started on the server instead of letting it run to the timeout.
- PostgreSQL optimistic grid edits cast both new and previously read custom enum, enum-array, and domain values to qualified native types, so stale-row comparisons work across those columns.
- A PostgreSQL query that returns more rows than the result cap now returns the capped rows promptly and stops the server query, instead of waiting for the server to finish or timing out.
- Connection-list rebuilds no longer remove a nested row list from the wrong GTK parent; GTK safety runs now fail on criticals.
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

### Security

- Agent result masking now treats `to_json` / `to_jsonb` and JSON object builders the same as `row_to_json` when deciding which columns to redact
- `SELECT … INTO` is now treated as a write, so read-only connections and agent read access refuse it instead of letting it create a table
- The row-count estimate that guards large writes no longer runs a side-effecting function in your WHERE clause before you approve the statement; such statements ask for approval without an estimate
- A session now refuses a script that hides BEGIN, COMMIT or ROLLBACK among other statements, so the transaction BookiE tracks always matches the one on the server
- A SQLite, PostgreSQL, MySQL or MariaDB connection marked read-only is now read-only in the database engine itself, so a statement the safety checks mistake for a read still cannot change data; a read-only SQLite connection no longer creates a missing file
- Importing a connection bundle now refuses a file over 16 MiB, or anything that is not a regular file, before reading it.
- Driver panic messages, which can contain query text or credentials, are no longer written to the logs or the terminal; only the location is. Set `TABLEPRO_DEBUG_PANICS=1` to print them while developing.

## [0.1.5] - 2026-09-27
- Choosing the system OpenSSH client inside the Flatpak build now stops immediately with a message to use the built-in SSH client.
- The Debian package now includes the SSH password helper that the system OpenSSH client needs.
- A lost connection stops reconnecting when the password, TLS setting or configuration is wrong and says why, instead of retrying forever.
- SQL completion no longer mixes up the columns of tables that share a name in different schemas.
- In the headless agent, a write interrupted on one connection no longer blocks governed writes on every other connection until restart.
- The headless agent now replaces a cached connection after a driver panic or an unusable-connection fault instead of reusing it because its health check still answers.

### Added
- Concurrent MongoDB first-page requests now share one schema census and retain the union of types observed across pages.

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
- Cancelling a connection attempt over the system OpenSSH client now stops its ssh master process and cleans up its private directory, instead of leaving it running in the background.
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

## Historical 0.1.x implementation ledger

### September 14 safety sprint

- Copy as IN clause uses the result's SQL dialect and reports omitted values
- SQL splitting preserves escaped quotes, nested PostgreSQL comments and escaped identifiers
- SQL editor warnings identify full-width characters, curly quotes and unusual spaces without rewriting queries
- Clipboard and file exports share exact value formatting, duplicate-column naming and `\x` binary encoding
- CSV export defaults to spreadsheet-safe text; raw text remains an explicit option
- File exports run off the GTK thread with progress, cancellation and atomic replacement
- DDL completion and table/view refresh retain their originating connection and reject stale results
- Redis browsing uses an isolated connection so interruption cannot change the normal command database
- MongoDB filters and inserts preserve BSON numbers when arbitrary-precision JSON is enabled
- MongoDB shell commands reject trailing text instead of executing only a valid prefix
- Replaced the yanked transitive chacha20 0.10.1 release with 0.10.2

### Bug and consistency follow-up

- SQLite preserves NULL in declared numeric, boolean, date/time, and blob columns, and preserves binary values on type mismatch
- JSON page export writes actual binary contents as `\x`-prefixed hexadecimal instead of a byte-count label
- Export writes use unique private temporary files, preventing overlapping exports and pre-existing symlinks from corrupting files
- Workspace restoration keeps the selected editor when unknown saved tab types are removed
- Daemon index and foreign-key metadata calls preserve the driver's controlled path
- GTK regressions cover JSON page contents and process restart; local driver checks include Redis, and fixture scripts resolve their workspace and isolate keyring sessions
- Optional DuckDB CI trusts only its checked-out workspace for Git ownership validation
- Retired the unshippable Oracle/ODPI driver path, which had no working build or runtime support

### September stabilization

- PostgreSQL pattern filters support non-text values without changing typed comparisons; invalid filters no longer produce unfiltered row counts
- Browse page/count planning is shared outside GTK; schema refresh avoids duplicate reads and retired-connection sidebar results are ignored
- The agent daemon preserves controlled view metadata through its tunnel-owning connection wrapper
- DuckDB bundles JSON and Parquet functionality, with flat-file regressions and an explicit optional-feature CI job
- PostgreSQL decodes rows during streaming and caches column type names, reducing large-result memory; measured development-build latency tradeoff is documented
- GTK testing isolates D-Bus/AT-SPI/portal state and waits for debounced search results before activating a favorite
- Documentation now tracks the stabilization evidence, ignored-test inventory and whole-app gaps through macOS 0.72

### Added
- Concurrent MongoDB first-page requests now share one schema census and retain the union of types observed across pages.

- Jump to Column searches browse/result metadata, distinguishes duplicate names by ordinal, and supports Ctrl+Shift+J.
- BookiE display name and original book icon; new package commands retain legacy aliases.
- Arch candidates can be built from an explicit local commit SHA and version before publishing a tag.

- SQL drafts are stored as complete private files instead of being truncated at 256 KiB; the first migration preserves the legacy workspace as a backup

- PostgreSQL views appear in the sidebar as read-only objects, listed through the same policy and timeout path as tables
- Saved connections can name a certificate authority, so a server whose certificate is issued privately can be verified with Verify Ca or Verify Full
- Policy crate with AST SQL classification, PolicyGuard, blast-radius rewrite, column masking, and policy.toml. Statements that read host files, run a program, or send SQL to another server are treated as administrative, so an agent is refused and a read-only connection denies them
- Environment field on saved connections (Local / Dev / Staging / Prod)
- Hash-chained audit journal at `$XDG_DATA_HOME/tablepro/audit.jsonl`
- Interactive `Connection::begin` transactions (PostgreSQL, MySQL, SQLite)
- TLS modes including VerifyFull default for new TLS connections, with certificate hostname and authority failures reported as TLS errors
- MCP bridge (interactive-app loopback HTTP plus on-demand agentd stdio) with scoped tokens and rate limiting, speaking the 2026-07-28 protocol revision while still accepting the two before it, and refusing to listen anywhere but the loopback interface
- Agents can read a table's columns, keys and indexes, count its rows exactly, and page through it, each through the same policy, allowlist and audit checks as any other tool and none of them needing write access
- Headless on-demand `tablepro-agentd` with required `--policy`, issuing read-only tokens by default, with an optional expiry and a way to write the token to an owner-only file instead of the terminal
- GTK approval dialog for policy `RequireApproval` decisions
- Server activity SQL templates (sessions, locks, long-running, replication), with the views an engine cannot answer shown as disabled and explained rather than failing when clicked
- Example policy file and MSSQL in AppStream metainfo
- SSH jump-host chains via nested `ssh.jump` in saved connections and `SshTunnel::open_chain`
- Keyset pagination helper for browse Next past the OFFSET threshold when primary keys are known
- Current-page CSV export with explicit non-snapshot semantics, written so another program never reads a half-finished file
- EXPLAIN plan dialog from the SQL editor and main menu
- Server version cached on connect and shown in the window subtitle
- ClickHouse, Redis, DuckDB, and MongoDB drivers
- Preferences → MCP token pairing (libsecret + loopback endpoint)
- Multi-window via New Window, with each window connecting on its own
- Saved connections can be put in a group, tagged, and starred as favourites, searched by any of those or by driver, and created by pasting a connection URL, whose password goes to the keyring rather than to disk
- Flathub submission notes and screenshot capture guide
- Rust file-size guardrail in preflight: soft 1200 / hard 1800 lines, with ratchet ceilings in `file-size-baselines.txt`
- Driver maturity labels in the Connect dialog (Experimental subtitle for Redis, MongoDB, and DuckDB)
- Driver maturity matrix in `docs/adding-drivers.md#driver-maturity`
- Drivers declare whether they can report indexes and foreign keys, so an engine that has none is no longer indistinguishable from a table that has none
- Windows integrated authentication for SQL Server through the current Kerberos ticket cache
- Principal-aware GUI approval routing with fail-closed behavior when no active window exists
- Explicit administrative SQL classification for PostgreSQL backend-control functions and MySQL KILL
- Weekly and manually dispatched full-workspace Clippy on current stable Rust, alongside the Rust 1.93 MSRV gate
- Arch/Omarchy Rust toolchain guidance and a traceable upstream Linux sync log
- Installed GTK safety checks for approval dismissal, approve-once scope, and unavailable audit storage
- Deterministic PostgreSQL release checks for TLS hostname and authority verification, tunnelled access, read-only denial, rollback, blocking locks, and reconnect
- Verify Full for PostgreSQL over SSH, using the original database hostname for certificate checks
- Named `:parameter` placeholders in the SQL editor, with a per-value type choice, sent to the database as bound parameters. Statement splitting and placeholder scanning follow the connected engine's own quoting, so a PostgreSQL function body is run whole and a MySQL `#` comment hides nothing but itself
- Schema-aware editor completion that offers tables after FROM and JOIN, and the columns of the tables in the statement, including through table aliases
- Saved query favorites in `favorites.json`, saved with Ctrl+D
- Open Quickly (Ctrl+P) over favorites, open tabs, and saved connections
- Direct PostgreSQL Unix-socket connections shared by GUI and agentd, with saved-path compatibility and a real socket fixture
- Required GTK connection-isolation smoke plus a daily five-attempt retry-free soak workflow
- Internal Arch RC packaging from an immutable commit archive and verified checksum
- Screen readers now announce the browse toolbar's insert-row button by name
- Installed GTK checks that a connection switch gates pending row edits and that a browse tab reads the connection it was reopened against
- Each window holds its own database connection, so several databases can be open at the same time in separate windows
- A binary column holding valid UTF-8 text now displays as that text instead of a byte count
- Browse marks a foreign-key column's header with 🔗
- Result grids can copy selected rows as TSV, CSV, JSON, Markdown, or an IN clause, show a row as JSON, and export displayed table or query results as CSV or JSON

### Changed

- BookiE app icon: open ledger with a grid page on a teal squircle.
- Preferences no longer offers an Admin MCP token. That option did not grant extra tools or bypass policy, and a stored Admin token still authenticates as read and write.
- Saving several row edits at once writes them in primary-key order, so two windows saving overlapping rows cannot deadlock against each other and a failed save reports the same row every time
- Stop is offered for the engines that can actually abort a statement, because the policy layer no longer hides a driver's cancellation support
- A cell edit is discarded with an explanation if the row moved out from under the editor, instead of being written to whichever row took its place
- Copy row as INSERT leaves out generated columns, which the database always rejects, and escapes a value the way the connected engine reads it, so a row holding a backslash copies as data rather than as SQL
- Stop and the query timeout now abort the running statement on MySQL, ClickHouse and SQLite, so the statement stops in the database and the session can keep writing afterwards
- A cancelled or timed-out SQL Server statement now reports that its outcome is unknown and closes the connection, instead of leaving every later query on that connection waiting forever
- SQLite results show the value of a computed column instead of a blank cell, so counts, aggregates and literal expressions read correctly, and a browse tab shows its total row count
- Browsing, row counts, structure reads, DDL, saving row edits, server activity, EXPLAIN and connecting all honour the configured query timeout instead of running without limit
- MSSQL uses native TLS and keeps its Kerberos service identity when SSH forwards the socket through localhost
- Workspace crates declare AGPL-3.0-or-later; cargo-deny allows that license and documents the rsa Marvin advisory ignore
- Linux UI and DDL modules split by domain: browse tab, grid, editor, app workspace helpers, and `sql_ddl` are directories of focused files instead of multi-thousand-line units
- Read-only is enforced by policy classification (data-modifying CTEs blocked)
- DatabaseService exposes only policy-gated connection handles
- Roadmap and production audit rewritten to match the governed data-plane plan
- Arbitrary SQL query soft row cap raised to 1,000,000 (truncated flag still set); browse pagination remains uncapped by that constant
- Agentd approval strategies are deny (default) or interactive TTY; automatic approval is test-only
- DuckDB driver is an optional `duckdb` Cargo feature (bundled build is large)
- Linux CI runs a non-GTK preflight job before the full GTK checks; local `./scripts/preflight.sh` mirrors that gate
- Policy evaluation takes the resolved connection EnvPolicy once; connection overrides no longer re-run evaluate
- Connect dialog TLS control is a mode picker (Disabled / Prefer / Require / Verify CA / Verify Full), defaulting to Verify Full for network drivers
- Local and development human writes require audit by default; best-effort unaudited writes require an explicit policy setting
- PostgreSQL query timeout and cancellation now wait within bounded deadlines for server confirmation before returning to GTK or MCP callers
- Connection changes validate a candidate before exclusively replacing the old workspace; failed candidates and failed saves keep the old connection active
- PostgreSQL browse pages resolve primary-key ordering before the first row fetch and append PK tie-breakers to user sorts
- Public package metadata names only drivers that are actually shipped

### Fixed

- Updated Rustls to 0.23.45 for RUSTSEC-2026-0285, including its required crypto dependencies.

- PostgreSQL decode failures stay errors, not false NULLs; INTERVAL, INET, CIDR, and LSN still render as text
- Binary values in a TEXT column opening as editable text
- SQL formatting preserves dialect-specific executable tokens and leaves statements unchanged when the formatter cannot safely reflow them
- SSH password and key-passphrase storage failures are reported instead of silently appearing to save successfully
- Column widths and filters persist in order with coalesced writes, preserve unreadable settings files, and flush on application exit

- A denied statement or dismissed approval is refused if that denial cannot be written to the audit journal
- The last open connection is reopened when the app starts. If it cannot connect, its tabs stay with that connection instead of attaching to another database
- Saved connection rows show the environment as a colour
- Measuring how many rows an UPDATE or DELETE would touch now uses the same timeout and cancellation as the write itself, instead of running an unbounded count first
- Reading a table's indexes and foreign keys now stops at the query timeout, and a failed read no longer pretends the table has none
- Structure tabs reopen after a reconnect, and the saved workspace no longer points at the wrong tab when a draft was skipped
- Closing the server activity dialog, or starting another activity query, stops the one that was still running
- Agent table lists and column descriptions now stop at the query timeout, reject invalid names, and are refused when audit storage is unavailable
- A policy file that cannot be read is no longer treated as an empty policy. Agent access stays off until the file can be loaded, and reopening Preferences keeps the previous policy instead of replacing it
- An empty mask list no longer turns off result masking. Use the environment setting that disables agent masking if that is what you want
- Query history export is written so another program never reads a half-finished file
- Setting a cell to NULL or deleting a row from the grid is discarded if the row moved, instead of changing whichever row took its place
- Switching connections no longer clears the previous connection's saved tabs
- A browse page or SQL run that finishes late no longer replaces a newer page or result
- Unsaved edits in one window no longer block or discard edits in another window
- Workspace changes are coalesced off the GTK thread, flushed before the last window closes, and reported instead of silently lost when persistence fails
- Saved connections, favorites, organization data, and MCP tokens preserve valid concurrent updates across processes and refuse malformed, oversized, symlinked, or permissively stored input where applicable
- MCP deadlines cover connection lookup, acquisition, metadata, preview execution, and rollback cleanup, with timed-out or uncertain guarded operations receiving terminal audit outcomes
- The headless agent refreshes cached sessions when saved transport settings change, bounds health checks and connection attempts, and keeps SSH tunnels alive only while issued connections still use them
- Secret Service failures are reported instead of being treated as empty database passwords, while SQLite and DuckDB connections do not require Secret Service
- The headless agent daemon reuses one database session per connection instead of opening a new one on every tool call
- The agent rate limiter forgets idle callers instead of growing for the lifetime of the process
- Saved connections are written so only the owner can read them, and a save that fails part way leaves the previous file intact
- Query plans use the connected engine's own EXPLAIN form, and engines without a query plan statement say so instead of failing on malformed SQL
- Reading a query plan through an agent no longer requires write access, while EXPLAIN ANALYZE stays governed as the write it performs
- Agent CSV export quotes values containing separators, quotation marks, or line breaks instead of producing corrupt rows
- Renaming a column in the structure editor applies the rename instead of failing, and the column's other edits apply to the new name
- PostgreSQL foreign key ON DELETE and ON UPDATE actions are reported as they are defined instead of always reading as NO ACTION
- Integer cells wider than 2^53 keep their exact value when edited instead of being rounded
- CSV export is limited to the loaded filtered page instead of silently paging an unordered changing table
- ClickHouse integration tests connect over plain HTTP instead of default VerifyFull HTTPS
- Flatpak CI bootstraps Rust 1.93 via rustup so the GNOME 47 SDK's older rust-stable extension is not required
- MCP write preview and other `begin()` paths now run statements through PolicyGuard instead of a raw driver transaction
- Agents are denied (and humans must approve) when a blast-radius estimate cannot be computed for UPDATE/DELETE
- Read-only connections deny unparseable SQL before any human approval fallback
- Activity termination accepts only validated positive numeric session identifiers
- Partial environment and connection policies inherit secure environment defaults and default masking rules
- Transactional batches request approval once instead of once per statement
- Mixed SQL batches retain DDL and unscoped UPDATE or DELETE restrictions regardless of statement order
- The agent daemon requires at least one existing saved connection when issuing a token
- Verified legacy audit journals rotate intact when upgrading to durable intent and outcome records
- PostgreSQL cancellation now stops the server query, records a terminal audit outcome, supports parameterized operations and transaction rollback, and discards sessions with unknown outcomes
- Approval dialogs attach to a visible application window when the desktop does not report an active window
- Saved connections expose a keyboard and screen-reader accessible open action
- Drop Table on a MongoDB collection now drops it instead of failing with an unsupported-statement error

### Removed

- Unused `Approve for session` approval outcome (no session-grant store existed)
- Broken stdio-under-systemd agentd unit and generated Python bytecode tracked in the repository
- MCP `search_query_history` until history can be connection-isolated, redacted, rate-limited, and audited

### Security

- Cached agent session reuse after Secret Service or key/certificate file rotation
- Unbounded PostgreSQL SCRAM iteration counts in sqlx-postgres
- Unbounded MongoDB SCRAM iteration counts
- SSH tunnel crashes or over-allocates against a hostile host (CVE-2026-73429, CVE-2026-48107, CVE-2026-46702)
- Unused rkyv 0.7 via rust_decimal (RUSTSEC-2026-0235)
- The headless agent daemon opens a saved connection through its configured SSH chain and verifies the certificate against the real database hostname, instead of dialling the database directly
- MongoDB connections honour the selected TLS mode and certificate authority instead of always connecting without encryption
- MySQL Verify Ca connections no longer crash the application
- ClickHouse connections distinguish encrypt-only from verifying TLS and can name a certificate authority, instead of always verifying against the bundled roots
- Redis connections can use TLS, including a named certificate authority, instead of failing whenever encryption is selected
- MongoDB and Redis connection attempts stop after five seconds instead of waiting on library defaults
- SSH tunnels stop waiting on a host that accepts a connection and never answers, reporting which host and port timed out
- MySQL server-control functions and SQL Server extended and system procedures are recognised as administrative, so agents are denied them the same way they are on PostgreSQL
- Agent write-scope checks classify SQL with the connected engine's dialect instead of always assuming PostgreSQL
- MCP HTTP rejects untrusted browser origins before JSON-RPC dispatch
- SSH host-key changes across key algorithms are treated as mismatches instead of first use
- Linux GitHub Actions are pinned to immutable commits
- TLS certificate verification modes (VerifyCa / VerifyFull) replace encrypt-only Require
- Agent results masked for sensitive column name patterns by default
- MCP tokens with an empty connection allowlist can no longer touch any connection
- SSH stack upgraded to russh 0.60.3 (fixes unbounded allocation advisories and drops vulnerable libcrux 0.0.4)
- Translation locale initialization runs before worker threads and uses the corrected gettext safety contract
- Production GUI and daemon paths no longer construct automatic approval sinks
- Mutations, DDL, administration, and transaction completion persist durable audit intent before database execution and fail closed when required records cannot be written
- Unknown or interrupted write outcomes block later governed writes across restarts and concurrent app and daemon processes
- The audit journal enforces private file permissions, verifies its hash chain, recovers interrupted appends, and serializes writers across processes
- Agentd and in-app MCP refuse service when required audit storage is unavailable
- PostgreSQL administrative and side-effecting function calls are denied to agents and read-only connections while literals and comments remain read-only
- Agent result masking also matches a sensitive column reached through an alias, a wrapping expression, or a subquery, instead of only the result set's reported column name
- A policy pattern the operator adds is applied on top of the built-in sensitive-column patterns instead of replacing them, and an unparseable mask pattern refuses to load instead of silently matching nothing
- An SSH jump hop configured for password authentication is refused instead of silently authenticating with the first hop's password
- ClickHouse identifier quoting escapes a backslash, so a table or column name reported by the server cannot break out of its quoted identifier
- Query history is stored at 0600, including its WAL and SHM files, instead of the filesystem default, so another local account cannot read past statement text
- The headless agent daemon's terminal approval prompt strips control characters from the displayed SQL and rule/reason text instead of writing them to the terminal as-is, and denies an unanswered prompt after two minutes instead of blocking every later tool call indefinitely
- Blast-radius limits now cover INSERT the same way they already covered UPDATE and DELETE, an UPDATE/DELETE's JOIN, USING, or FROM clause is included in the affected-row estimate instead of being silently dropped, and a batch of statements with a known row count each (for example several literal-values INSERTs) is estimated by summing them instead of always requiring approval it can't satisfy
- The administrative-function list denies more PostgreSQL host-access and dblink calls (pg_file_write, pg_file_unlink, dblink_open, dblink_fetch, dblink_connect_u, pg_stat_statements_reset), and SQLite's fileio and extension-loading functions (writefile, readfile, load_extension) are recognised as administrative for the first time
- The MCP execute_query tool refuses a statement that writes instead of committing it directly, so a write can no longer skip execute_write's preview-by-default workflow
- MySQL connections tunnelled through SSH verify Verify Ca and Verify Full against the real database hostname instead of the local tunnel endpoint, matching how PostgreSQL already worked
- Saving a Browse tab edit made before a Structure tab dropped or reordered a column now shows a clear "reload and reapply" error instead of crashing the whole application
- Two windows can no longer open the same saved connection at once; the second is refused with a toast instead of silently taking over the first window's live connection
- Closing a secondary window now closes its database connection, SSH tunnel, and reconnect monitor, and cancels its health-poll and history-prune timers, instead of leaving them running for the rest of the process
- GRANT, REVOKE, COPY, MERGE, and CREATE FUNCTION now name the table or object they target in the audit trail and approval dialog instead of showing a blank object list
- A misspelled policy.toml environment or field name, or a connection override keyed by a UUID typed in a different case, now refuses to load instead of the override silently never applying
- The MCP tools/list method requires the same token tools/call already does, instead of disclosing the full tool catalogue to any caller that can reach the listener
- The MCP stdio server recovers from a non-UTF-8 line the same way it already does from invalid JSON, instead of ending the whole session
- Repeated failed MCP authentication attempts are rate limited even when every attempt uses a different token string
- The MCP HTTP transport now enforces the same request-size limit the stdio transport already did, instead of a larger framework default
- A malformed Redis database index (a typo, stray text) refuses the connection instead of silently landing on database 0, usually the production database
- The query-timeout preference is cached instead of re-read from disk on the GTK thread before every query dispatch
- Preferences → Default page size now offers the same fixed choices (100 / 500 / 1,000 / 5,000 / 10,000) the per-tab paginator does, so a chosen default can no longer silently revert to 1,000 after restart
- Copy row as INSERT now copies the row shown at the clicked position instead of a different row's values when a draft row is pending
- Closing an editor or structure tab now disconnects its dark-mode-change handler instead of leaking the tab's widget tree for the rest of the process
- The editor font-size preference now scopes to the SQL editor instead of resizing every text view on screen, including the EXPLAIN dialog and JSON popover
- Browsing a different Redis database from the sidebar no longer leaves later queries on that connection running against it; the connection's own database is restored afterward
- A failed row-count query now clears the paginator's total and disables Last Page instead of leaving the previous total on screen as if it were still accurate
- An approval dialog now appears on the window that owns the connection the statement runs on, instead of whichever window last had keyboard focus
- SQL Server Verify Ca and Verify Full connections now use a saved certificate authority to verify the server, instead of only ever checking the system trust store
- A KILL QUERY dispatch that outlasts its own two-second cancellation window now finishes and closes the connection it used instead of leaving MySQL's single-slot cancellation pool with a connection whose response was never fully read
- MongoDB connections always request a direct connection, so a replica set member's advertised hostname can no longer redirect the client away from the saved host or its SSH tunnel
- MongoDB errors are now classified from the driver's structured error kind instead of substring-matching the error message, so an unrelated failure whose text happens to contain "connection" or "auth" is no longer misreported as connection-refused or an authentication failure
- Connecting to PostgreSQL or MySQL now makes one authentication attempt instead of two, so a server that locks an account out after repeated failures no longer counts a single Connect click twice
- A cancellation request that outlasts its own two-second dispatch window now finishes and closes the connection it used on PostgreSQL as well as MySQL, instead of risking a protocol-desynced connection in the single-slot cancellation pool
- Restoring a saved workspace with a "new table" draft or an unnamed table tab ahead of the previously active tab now reactivates the correct tab instead of one shifted by the tabs that were never persisted
- The audit journal's hash chain is now verified against each record's exact original bytes instead of a re-serialization of its parsed contents, so a future change to how an audit event is written can no longer retroactively break verification of records already on disk
- SQLite values that don't match their column's declared type (SQLite's type affinity can store a row's value in a different storage class than the column declares) now keep their text or byte representation instead of silently appearing as an empty cell
- MySQL BIGINT UNSIGNED values past i64's range now show their full digits as text instead of appearing as an empty cell
- A SQL Server NUMERIC value past rust_decimal's range no longer crashes the query; it now shows its full precision as text instead
- MySQL DECIMAL values past rust_decimal's range now show their exact digits as text instead of appearing as an empty cell

## Historical engineering records

This index is the entry point for dated implementation and validation history.
The linked archives preserve source-pinned details and case evidence; they are
not current task instructions.

- **Sprint and milestone history:** [0.1.x → 0.2 delivery record](docs/archive/bookie-0.2-history.md).
- **B4 implementation history:** [transport, policy, session and UI packets](docs/archive/b4-history.md).
- **Value contracts:** [driver and consumer case results](docs/archive/value-contract-history.md); current lookup is the [value evidence index](docs/value-contracts.md).
- **Type contracts:** [historical matrices and reconciliation](docs/archive/type-contract-history.md); current remaining work is the [B3 board](docs/type-contract-strategy.md).
- **Connections:** [dated connection audit and follow-ups](docs/archive/connections-history.md); current behavior is in [connections](docs/connections.md).
- **Testing:** [upstream test adoption record](docs/archive/testing-history.md); runnable layers are in [testing](docs/testing.md).
- **Validation:** [local validation checkpoints](docs/archive/validation-history.md); current commands are in the [validation playbook](docs/validation-playbook.md).
- **External audit (post-0.2 plan):** [deferred restructuring plan](docs/archive/external-audit-2026-10-06.md) and [client review](docs/archive/external-audit-client-review-2026-10-06.md) (moved from the repository root on 2026-10-10).
- **BookiE 0.1.1:** retired and superseded by the 0.2 sprint; the earlier release review remains in [September 14 evidence](docs/archive/sprint-2026-09-14.md).
