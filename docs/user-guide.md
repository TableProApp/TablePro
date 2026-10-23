# BookiE user guide

BookiE is a database client for Linux. It opens PostgreSQL, MySQL and MariaDB, SQLite, SQL Server, ClickHouse, MongoDB, Redis and (when built with it) DuckDB. This guide covers everyday use. Developer documentation starts at [docs/README.md](README.md).

## Connect

1. Click **New connection** (the `+` in the window header).
2. Pick the database type, then fill in host, port, database and user. For SQLite and DuckDB, choose the file.
3. Click **Test** to check the details, then **Connect**.

For MySQL and MariaDB, choose a local socket file instead of a host to connect through a Unix socket; the path is saved with the connection and exported in bundles. For PostgreSQL, the schema filter menu hides schema groups per connection and restores them. PostgreSQL login and missing-database errors stop the app's reconnect loop; the initial SQLx pool startup may retry until its connection deadline. The General preferences choose how NULL is shown in the grid (NULL, the empty-set symbol or (null)).

Passwords are kept in your desktop keyring, never in BookiE's own files.

- **From the file manager or a terminal**: choose BookiE in **Open With** for a SQLite file, or run `bookie books.db` (SQLite or DuckDB) or `bookie postgres://user@host:5432/database`. A file must exist and be a database of the engine its extension names (`.sqlite`, `.sqlite3`, `.db`, `.db3`, `.s3db` or `.duckdb`, `.ddb`). A URL opens a dialog to confirm before it is saved and connected. If BookiE is already running, the running window handles the request. Avoid putting a password in a URL on the command line, because other users on the machine can see it in the process list.
- **SSH**: the form configures one SSH host. The built-in transport can use saved multi-hop routes, but the form cannot edit them yet. System OpenSSH uses jump hosts from your SSH configuration. BookiE asks before trusting an unknown host key, including keys presented by a jump host.
- **TLS**: choose how strictly the server certificate is checked. "Verify full" checks both the certificate authority and the host name.
- **Environment and read-only**: mark a connection as production, staging or local, and tick **Read-only** to refuse every change on it. A production connection shows a red **Production** badge, a tinted header bar and `[Production]` at the start of its window title, so it stands out in the taskbar and Alt-Tab.
- **Import from URL** fills the form from a connection URL such as `postgres://user@host:5432/db`. A local Unix socket is written `mysql://user@/db?socket=/run/mysqld/mysqld.sock` or `postgres://user@/db?host=/run/postgresql`.
- **Share connections**: export or import connections from the menu in the saved list. Encrypt the export with a passphrase to include stored database and SSH credentials. Plaintext exports contain no credentials.

## Browse a table

Click a table in the sidebar. It opens as a preview tab, marked with an icon, and the next table click reuses that preview. Edit the table or choose **Keep Tab** from the tab menu to keep it open. Tabs with pending edits are kept automatically. Ctrl+click or the sidebar's **Open in new tab** action always creates a durable tab. Turn off **Reuse one tab when opening tables** in Preferences to give every table its own tab; a table that is already open is still selected instead of duplicated. The sidebar groups tables and views under each schema; click a group to collapse it, and type in the search to find a table.

Use First, Previous, Next and Last to move through table pages. Unsorted tables with primary keys use keyset seeks for deep Previous navigation and Last. Each page is a separate read, so concurrent database changes can alter which rows appear between page requests; browsing does not hold a snapshot across pages.

- **Edit**: double-click a cell, or press F2 or Enter. Changes stay pending (shown with a dot on the tab) until you press Ctrl+S. **Preview SQL** in the bar below the grid shows the statements and values that Save would run, without running them. Ctrl+Z and Ctrl+Y undo and redo pending changes.
- **Insert and delete**: Ctrl+N inserts a row, Delete removes the selected rows. Ctrl+Shift+N sets the focused cell to NULL.
- **Filter and sort**: Ctrl+F opens the filter bar. Save structured filters by name for the current connection, schema and table, then select and apply them later; you can rename or delete saved filters there too. Click a column header to sort. Right-click a cell and choose **Filter by This Value** for a quick filter. On a foreign key cell, **Go to Referenced Row** opens the referenced table filtered to that row (composite keys use every column of the key). If the column belongs to multiple foreign keys, choose the target table. Click a cell and press Ctrl+V to paste tab-separated text (for example copied from a spreadsheet) into the cells from that one: each value is checked like a typed edit, nothing is applied if any cell is refused, and the result is a set of pending changes you review and save. An empty pasted value on a nullable column becomes NULL. On PostgreSQL (a column whose type is an enum, or a domain over one; not arrays of enums) and on MySQL and MariaDB, double-clicking an ENUM cell opens a list of its members (choose one with the mouse or the arrow keys and Enter), and a SET cell opens a list with a check for each member and an Apply button; the empty member shows as (empty) and is stored as the empty value, not NULL.
- **Columns**: the **Columns…** entry in the cell menu hides or shows columns. Drag a header to reorder columns. Both are remembered per table. **Reset** in the Columns dialog forgets the widths you set by dragging.
- **Find**: Ctrl+Alt+F lists loaded rows that contain a text.
- **Long values**: cells longer than 8 KiB show a bounded preview and the full value's size. Text and JSON previews show up to 512 Unicode characters. **View Value** opens the whole value, and **Copy Value** copies it in full. Right-click an editable text or JSON cell and choose **Edit Full Value…** to edit the entire value up to 1 MiB. **Apply** stages the value for review; invalid JSON stays in the dialog without staging. **Format JSON** visibly formats semantic JSON values. Source-text JSON keeps its exact text, including key order and number spelling. **Set to NULL** is separate from empty text, JSON `null`, and the text `null`. **Cancel** stages nothing. Values over 1 MiB are not supported in this dialog. SQL result grids remain read-only. Exports use full values when fetched; full-row copy and current-page export are refused if hidden columns leave values unavailable.
- **Row inspector**: shows every column of the selected row with its type.
- **Selection statistics**: select several rows and open the selection badge to see count, sum, average, min and max per numeric column; **Copy summary** copies them.

## Run SQL

In a focused result grid, **Ctrl+Shift+J** opens **Jump to Column** and **Ctrl+Alt+F** opens **Find in Loaded Rows**. Selecting a match or dismissing either dialog returns focus to row navigation. **Ctrl+Home** and **Ctrl+End** move to the first and last loaded row; they do not fetch additional rows.

Ctrl+E opens a SQL editor tab for the current connection.

Supported single-statement PostgreSQL `SELECT`s load progressively. The grid keeps up to four pages of 5,000 rows within a shared 64 MiB estimated row budget, always keeping the newest page; use **Previous page** and **Next page** to navigate retained pages. The row summary states which rows remain when older pages leave the forward-only window. Discarded rows cannot be revisited there. Other engines and unsupported query shapes load a capped result. A truncated, failed or cancelled result is incomplete; see [result limits](known-limitations.md#data-and-values).

Automatic completion, statement shading and character diagnostics are available for SQL buffers up to 200,000 UTF-8 bytes. Larger files remain editable, saveable and executable; automatic assistance is disabled to bound background analysis.

SQL completion offers keywords and scoped table and column names. Choosing an identifier inserts its complete quoted SQL name. Table names keep their schema; column suggestions after an alias keep that alias. Arbitrary words elsewhere in the editor are not suggestions.

While a query runs again, the previous result stays on screen, dimmed, until the new result, an error, or a cancel or timeout message replaces it.

Click a sortable result column header to order the rows already loaded in that result. This is a local view change and does not run the SQL again, including for write statements that return rows. SQL NULL values stay last; columns with mixed, JSON or undecodable values cannot be sorted. Text follows the desktop locale collation, which can differ from the database collation.

Right-click a result cell and choose **Filter by This Value** to filter the loaded rows in that result. This also works on pinned results, shows visible and loaded row counts, and does not run the SQL again.

When a query stops at the query timeout, the editor toolbar offers **Run again with a longer timeout** (four times as long, up to 24 hours). It runs the same SQL that timed out, applies to that run only, and leaves the saved timeout unchanged. Starting any other run removes the button.

Use **Split** in the editor toolbar to show the same query in a second side-by-side pane. Edits and the caret are shared; each pane keeps its own scroll position.

To collapse a multiline SQL block, place the cursor inside it and press **Ctrl+Shift+[**. Click its gutter marker to unfold it, or choose **Unfold all** in the toolbar. **Ctrl+Shift+]** also unfolds every block. Folding hides lines in the editor without changing the SQL that runs. Editing the query clears folds so hidden text cannot be mistaken for the current query.

- Ctrl+Enter (and the Run button) runs the selected text when something other than blank space is selected, otherwise the whole script (a find match left selected counts as a selection); Ctrl+Shift+Enter runs the statement under the cursor (shaded). Escape cancels a running query when the server supports it. The arrow beside **Run** offers whole-script and current-statement actions with their shortcuts. After execution, its **File output** section lists loaded result sets separately; a streamed result offers an explicitly labeled rerun export.
- Each statement has a result view. SQL Server statements that return multiple result sets show those sets in order within that view. More than five statement results collapse into a drop-down. **Pin results** keeps the current results above the next run.
- After a run, the gutter marks each statement with a tick or a cross. For supported SQL dialects, SQL text inside comments does not receive a statement mark.
- A failed statement shows the error with **Copy error**. When the server supplies a position for the original SQL, **Go to error** in the result and **Errors** views restores the editor and places the caret there. Positions count Unicode characters and refer to the statement that failed, including when the same statement occurs twice. Editing the query, running it again, or changing its connection requires a fresh error before an old action can navigate. Errors without a usable position remain readable and copyable.
- `:name` placeholders ask for values before the statement runs and send them as bound parameters, never pasted into the SQL.
- Completion offers tables after `FROM` and `JOIN` and columns elsewhere.
- **Session** keeps one connection for the tab, so settings, temporary tables and transactions carry over between runs. MySQL sessions allow locking reads, user variables, savepoints and supported `SHOW` forms inside an open transaction; raw transaction-control SQL, DDL, account statements, `LOCK TABLES` and `SET autocommit` remain refused. `ROLLBACK` does not undo user-variable assignments or release named locks acquired by functions in assignment expressions; close the session to release those locks.
- Outside **Session**, a lone `BEGIN`, `COMMIT` or `ROLLBACK` is refused before database dispatch, including when run under the cursor. In a Session, send transaction-control statements separately so BookiE can track the transaction. `COMMIT` without an open transaction and transaction control hidden in a multi-statement script are refused.
- **Explain** shows the plan of the selected text, or of the whole editor when nothing is selected. For PostgreSQL and SQLite the plan opens as a **Tree** (indented by nesting, with a bar for each step's share of the estimated cost; hover a bar for the numbers) and the **Text** tab keeps the raw plan. Other engines show the text plan only. The costs are the planner's estimates; nothing is executed.
- Ctrl+H opens query history in a panel beneath the workspace. Statements that set a password, an encryption key or a connection secret are not saved there. Search, filter, pin, export or reopen queries there; **Close history** returns the full space to your current workspace. Ctrl+D saves the query as a favorite, and Ctrl+P opens Open Quickly for favorites, tabs and connections.

A session with an open transaction also shows **Transaction active**, **Commit & close session**, and **Roll back & close session**. Both actions end that editor session. They are unavailable while a statement or session operation is running. A failed commit keeps the existing recovery behavior; an aborted PostgreSQL transaction can report a rollback instead of a commit.

The header's **Tables sidebar** button shows or hides database navigation at any window width. In a wide window the sidebar is docked: drag the divider or focus its native handle and use the keyboard to resize it. In a window narrower than 960 px the sidebar becomes an overlay that stays closed after connecting and returns docked when the window is widened. The arrow beside a table or view expands its fields without opening another tab. Names lead, engine types are secondary, and primary-key fields show a key icon. **Structure…** opens the full metadata view. Expansion previews up to 256 fields per object, with at most 2,048 fields retained across expanded objects and four metadata requests at once. Collapse and expand to retry a failed load; collapsing releases its field budget.

Grid headers show the column name and exact engine type spelling on separate lines. The native header menu shows **Column details**, including keys, nullability and the column comment. Comments are kept out of the header so they do not increase every header's height.

## Import and export

- **Export** opens one dialog with **Scope** before **Format**. A table uses its current page and active server-side filter; **All matching table rows** explains the snapshot requirement and cannot start an export. A query exports its loaded result columns, including joins and aliases, without running SQL again. A streamed result's all-row export explicitly runs the guarded query again and can observe changed data. Choose CSV, JSON, Markdown, HTML, XML, SQL or an Excel workbook after reviewing the scope. Full-table export remains refused until a consistent snapshot path is supported.
  SQL row export and Copy as INSERT are not database backups; see the
  [identity and generated-column limitations](known-limitations.md#data-and-values).
- **Import**: right-click a table and choose **Import CSV…** to load a CSV file
  into it, or use the button on a schema header to create a new table from a CSV
  file. A `.xlsx` workbook is read from its first worksheet that has data, using the values the file stores (formulas show their last saved result, dates as ISO text); there is no sheet picker yet. Separator, header row and column mapping are detected and can be changed, as can the quote character, backslash escaping of quotes and the text encoding (UTF-8, Windows-1252 or UTF-16; a file that is not UTF-8 opens with a matching choice).
  For an existing table, use **Remember mapping** and **Restore mapping** to reuse
  the destination choices for that connection and table. Generated columns stay on
  Skip. PostgreSQL, MySQL/MariaDB and SQLite accept mapped auto-increment values;
  SQL Server identity columns stay on Skip. See
  [known limitations](known-limitations.md#data-and-values).
  PostgreSQL `timestamptz` values should include an explicit zone; unzoned values are
  currently treated as UTC. See [known limitations](known-limitations.md#data-and-values).

## Safety

BookiE checks every statement before it runs:

- Writes on a read-only connection are refused.
- Depending on the connection's environment and your policy, risky statements (for example a `DELETE` without `WHERE`, or schema changes in production) ask for your approval first. The time spent waiting for approval is not counted in the statement's elapsed time.
- BookiE records governed operation outcomes in a local audit journal when it is available. MCP and operations that require audit persistence are refused if the journal is unavailable. A Local or Dev policy may allow a human write to continue after audit-intent failure; that write may succeed without being recorded.

## Back up and restore PostgreSQL

From the app menu, choose **Back Up Database…** to save a custom-format `.dump` file, or **Restore from Backup…** to restore one. These actions are available for PostgreSQL connections and use the installed `pg_dump` and `pg_restore` tools. They work over the connection's configured SSH and TLS route. Restore requires a writable connection and approval; both operations are audited. Cancel stops the running tool. Cancelling a backup removes its partial file. If a restore is cancelled or fails after `pg_restore` starts, the result is unknown. BookiE records that outcome and keeps governed writes blocked on that connection, including after reconnect; other connections remain available. There is not yet an in-app action to reconcile it. Check the database state before deciding how to proceed.

## Snapshots

Database snapshots are not available. [ADR 0015](decisions/0015-database-snapshots.md) records an accepted design; implementation is listed as post-0.2.0 work in the [backlog](backlog.md), with no release target. PostgreSQL logical backup and restore are available separately; see [Back up and restore PostgreSQL](#back-up-and-restore-postgresql).

## AI agents (MCP)

BookiE can let an AI assistant use your saved connections through the Model Context Protocol. Open **Preferences → MCP** to create a token, choose which connections it may use and which tools it may call. The token appears once; the dialog reports whether it was saved in the system keyring. If saving fails, copy it into your MCP client configuration before closing the dialog. Every agent statement goes through the same safety checks, and agent changes follow the approval rules of the connection's environment. `bookie-agentd` runs the same server without the window, for headless use.

Every statement BookiE runs for you or for an agent is recorded in a local audit journal. Open **Audit Log** from the main menu to read it: each operation shows its connection, principal, kind, outcome, row count and duration, and expands to its operation id, policy rule, stored statement and error. Statement text appears in the redacted form the journal keeps.

MCP data responses use the versioned `bookie-tagged-v1` format. Check `value_format` and decode each cell by `$type`; values are tagged even when they fit in a JSON number. A wide integer is returned like this:

```json
{"$type":"int64","value":"9007199254740993"}
```

Keep the digits as text or parse them with a lossless integer type. Parsed JSON uses nested tags, including `json_number` values whose digits stay strings. `json_text` contains the original JSON text; keep it as text when duplicate keys, whitespace or number spelling matter. Clients that expect primitive JSON cells must update their decoder. CSV exports keep their existing format.

The tool list carries read-only and destructive hints for MCP clients. Only the table and metadata tools are marked read-only. Tools that run SQL are marked as able to change data, even when they preview first. The hints are advisory: they never grant a permission and the safety checks still decide every call.

## Keyboard shortcuts

Press Ctrl+? for the full list. The most used:

| Keys | Action |
|---|---|
| Ctrl+E / Ctrl+T | New SQL editor tab |
| Ctrl+Enter | Run the selection, or the script when nothing is selected |
| Ctrl+Shift+Enter | Run the statement at the cursor |
| Ctrl+S | Save pending changes (or the SQL file) |
| Ctrl+Z / Ctrl+Y | Undo / redo a pending change |
| Ctrl+F | Filter rows |
| Ctrl+Alt+F | Find in loaded rows |
| Ctrl+Shift+J | Jump to a column |
| Ctrl+Shift+L | Reveal the open table in the sidebar |
| Ctrl+P | Open Quickly |
| Ctrl+H | Query history |
| Ctrl+Tab | Most recently used tab |
| Ctrl+/ | Toggle a line comment |
| Ctrl+Shift+[ | Fold the SQL block at the cursor |
| Ctrl+Shift+] | Unfold all SQL blocks |
| F5 | Refresh the table |
| Ctrl+W | Close the tab |

### Results panel

Each SQL editor keeps its own bottom panel. **Results** or **Ctrl+J** hides or shows it from the SQL editor or result grid. Hiding preserves the loaded rows, selection and current result set; it does not run SQL. **Show result sets** returns from the Errors view to the existing result selector. **Errors** lists failures from the latest completed run, including streamed failures and timeouts; informational server messages are not implemented by this panel.

Drag the divider to resize the panel. **Maximize results** hides the SQL area; **Restore editor** returns to the previous divider position and SQL focus. Hiding a maximized panel also restores the editor. Panel size is retained within the open editor, not across an application restart. Closing the query releases its panel with the rest of that editor.
