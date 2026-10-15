# BookiE user guide

BookiE is a database client for Linux. It opens PostgreSQL, MySQL and MariaDB, SQLite, SQL Server, ClickHouse, MongoDB, Redis and (when built with it) DuckDB. This guide covers everyday use. Developer documentation starts at [docs/README.md](README.md).

## Connect

1. Click **New connection** (the `+` in the window header).
2. Pick the database type, then fill in host, port, database and user. For SQLite and DuckDB, choose the file.
3. Click **Test** to check the details, then **Connect**.

For MySQL and MariaDB, choose a local socket file instead of a host to connect through a Unix socket; the path is saved with the connection and exported in bundles. For PostgreSQL, the schema filter menu hides schema groups per connection and restores them. A wrong PostgreSQL password or database is reported at once and is not retried. The General preferences choose how NULL is shown in the grid (NULL, the empty-set symbol or (null)).

Passwords are kept in your desktop keyring, never in BookiE's own files.

- **SSH**: the form configures one SSH host. The built-in transport can use saved multi-hop routes, but the form cannot edit them yet. System OpenSSH uses jump hosts from your SSH configuration. BookiE asks before trusting a built-in host key it has not seen.
- **TLS**: choose how strictly the server certificate is checked. "Verify full" checks both the certificate authority and the host name.
- **Environment and read-only**: mark a connection as production, staging or local, and tick **Read-only** to refuse every change on it.
- **Import from URL** fills the form from a network connection URL such as `postgres://user@host:5432/db`. Local Unix socket paths must be set in the form or restored from a connection bundle.
- **Share connections**: export or import connections from the menu in the saved list. Encrypt the export with a passphrase to include stored database and SSH credentials. Plaintext exports contain no credentials.

## Browse a table

Click a table in the sidebar. It opens as a preview tab, marked with an icon, and the next table click reuses that preview. Edit the table or choose **Keep Tab** from the tab menu to keep it open. Tabs with pending edits are kept automatically. Ctrl+click or the sidebar's **Open in new tab** action always creates a durable tab. The sidebar groups tables and views under each schema; click a group to collapse it, and type in the search to find a table.

- **Edit**: double-click a cell, or press F2 or Enter. Changes stay pending (shown with a dot on the tab) until you press Ctrl+S. Ctrl+Z and Ctrl+Y undo and redo pending changes.
- **Insert and delete**: Ctrl+N inserts a row, Delete removes the selected rows. Ctrl+Shift+N sets the focused cell to NULL.
- **Filter and sort**: Ctrl+F opens the filter bar. Save structured filters by name for the current connection, schema and table, then select and apply them later; you can rename or delete saved filters there too. Click a column header to sort. Right-click a cell and choose **Filter by This Value** for a quick filter. On a foreign key cell, **Go to Referenced Row** opens the referenced table filtered to that row (composite keys use every column of the key). If the column belongs to multiple foreign keys, choose the target table. Click a cell and press Ctrl+V to paste tab-separated text (for example copied from a spreadsheet) into the cells from that one: each value is checked like a typed edit, nothing is applied if any cell is refused, and the result is a set of pending changes you review and save. An empty pasted value on a nullable column becomes NULL. On PostgreSQL (a column whose type is an enum, or a domain over one; not arrays of enums) and on MySQL and MariaDB, double-clicking an ENUM cell opens a list of its members (choose one with the mouse or the arrow keys and Enter), and a SET cell opens a list with a check for each member and an Apply button; the empty member shows as (empty) and is stored as the empty value, not NULL.
- **Columns**: the **Columns…** entry in the cell menu hides or shows columns. Drag a header to reorder columns. Both are remembered per table.
- **Find**: Ctrl+Alt+F lists loaded rows that contain a text.
- **Long values**: cells longer than 8 KiB show a preview and the full value's size. **View Value** opens the whole value, and **Copy Value** copies it in full. Right-click an editable text cell and choose **Edit Full Value…** to edit the entire value up to 1 MiB. **Apply** stages the text for review; **Set to NULL** is separate, so empty text remains empty. **Cancel** stages nothing. JSON previews and values over 1 MiB are not supported in this dialog yet ([#610](https://github.com/cozyGarage/BookiE/issues/610)). SQL result grids remain read-only. Exports use full values when fetched; full-row copy and current-page export are refused if hidden columns leave values unavailable.
- **Row inspector**: shows every column of the selected row with its type.
- **Selection statistics**: select several rows and open the selection badge to see count, sum, average, min and max per numeric column; **Copy summary** copies them.

## Run SQL

Ctrl+E opens a SQL editor tab for the current connection.

Click a sortable result column header to order the rows already loaded in that result. This is a local view change and does not run the SQL again, including for write statements that return rows. SQL NULL values stay last; columns with mixed or undecodable values cannot be sorted. Text uses local value ordering, which can differ from the database collation.

Right-click a result cell and choose **Filter by This Value** to filter the loaded rows in that result. This also works on pinned results, shows visible and loaded row counts, and does not run the SQL again.

Use **Split** in the editor toolbar to show the same query in a second side-by-side pane. Edits and the caret are shared; each pane keeps its own scroll position.

To collapse a multiline SQL block, place the cursor inside it and press **Ctrl+Shift+[**. Click its gutter marker to unfold it, or choose **Unfold all** in the toolbar. **Ctrl+Shift+]** also unfolds every block. Folding hides lines in the editor without changing the SQL that runs. Editing the query clears folds so hidden text cannot be mistaken for the current query.

- Ctrl+Enter runs the whole script; Ctrl+Shift+Enter runs the statement under the cursor (shaded). Escape cancels a running query when the server supports it.
- Each statement has a result view. SQL Server statements that return multiple result sets show those sets in order within that view. More than five statement results collapse into a drop-down. **Pin results** keeps the current results above the next run.
- After a run, the gutter marks each statement with a tick or a cross.
- A failed statement shows the error, with **Copy error**, and on PostgreSQL the line and column of the error inside that statement.
- `:name` placeholders ask for values before the statement runs and send them as bound parameters, never pasted into the SQL.
- Completion offers tables after `FROM` and `JOIN` and columns elsewhere.
- **Session** keeps one connection for the tab, so settings, temporary tables and transactions carry over between runs.
- **Explain** shows the plan of the selected text, or of the whole editor when nothing is selected. For PostgreSQL and SQLite the plan opens as a **Tree** (indented by nesting, with a bar for each step's share of the estimated cost; hover a bar for the numbers) and the **Text** tab keeps the raw plan. Other engines show the text plan only. The costs are the planner's estimates; nothing is executed.
- Ctrl+H opens query history in a panel beneath the workspace. Search, filter, pin, export or reopen queries there; **Close history** returns the full space to your current workspace. Ctrl+D saves the query as a favorite, and Ctrl+P opens Open Quickly for favorites, tabs and connections.

## Import and export

- **Export**: from a table or a result, choose CSV, JSON, Markdown, HTML, XML, SQL
  or an Excel workbook. Export the current table page or loaded query results.
  Full-table export is refused until a consistent snapshot path is supported.
- **Import**: right-click a table and choose **Import CSV…** to load a CSV file
  into it, or use the button on a schema header to create a new table from a CSV
  file. Separator, header row and column mapping are detected and can be changed.
  For an existing table, use **Remember mapping** and **Restore mapping** to reuse
  the destination choices for that connection and table. Auto-increment and generated
  columns stay on Skip; the database supplies their values. Explicit values for
  auto-increment columns cannot currently be imported ([known limitations](known-limitations.md#data-and-values)).
  PostgreSQL `timestamptz` values should include an explicit zone; unzoned values are
  currently treated as UTC. See [known limitations](known-limitations.md#data-and-values).

## Safety

BookiE checks every statement before it runs:

- Writes on a read-only connection are refused.
- Depending on the connection's environment and your policy, risky statements (for example a `DELETE` without `WHERE`, or schema changes in production) ask for your approval first. The time spent waiting for approval is not counted in the statement's elapsed time.
- Every executed, refused or cancelled operation is written to an audit journal on your machine.

## Snapshots

Planned for a 0.2.x release, after 0.2.0: take a snapshot of a database before an experiment and restore it with one click, starting with PostgreSQL. See [ADR 0015](decisions/0015-database-snapshots.md) and ledger rows SNAP-1 to SNAP-4 in [known-issues.md](known-issues.md).

## AI agents (MCP)

BookiE can let an AI assistant use your saved connections through the Model Context Protocol. Open **Preferences → MCP** to create a token, choose which connections it may use and which tools it may call. The token appears once; the dialog reports whether it was saved in the system keyring. If saving fails, copy it into your MCP client configuration before closing the dialog. Every agent statement goes through the same safety checks, and agent changes follow the approval rules of the connection's environment. `bookie-agentd` runs the same server without the window, for headless use.

The tool list carries read-only and destructive hints for MCP clients. Only the table and metadata tools are marked read-only. Tools that run SQL are marked as able to change data, even when they preview first. The hints are advisory: they never grant a permission and the safety checks still decide every call.

## Keyboard shortcuts

Press Ctrl+? for the full list. The most used:

| Keys | Action |
|---|---|
| Ctrl+E / Ctrl+T | New SQL editor tab |
| Ctrl+Enter | Run the script |
| Ctrl+Shift+Enter | Run the statement at the cursor |
| Ctrl+S | Save pending changes (or the SQL file) |
| Ctrl+Z / Ctrl+Y | Undo / redo a pending change |
| Ctrl+F | Filter rows |
| Ctrl+Alt+F | Find in loaded rows |
| Ctrl+Shift+J | Jump to a column |
| Ctrl+P | Open Quickly |
| Ctrl+H | Query history |
| Ctrl+Tab | Most recently used tab |
| Ctrl+/ | Toggle a line comment |
| Ctrl+Shift+[ | Fold the SQL block at the cursor |
| Ctrl+Shift+] | Unfold all SQL blocks |
| F5 | Refresh the table |
| Ctrl+W | Close the tab |
