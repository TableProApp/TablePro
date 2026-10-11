# BookiE user guide

BookiE is a database client for Linux. It opens PostgreSQL, MySQL and MariaDB,
SQLite, SQL Server, ClickHouse, MongoDB, Redis and (when built with it) DuckDB.
This guide covers everyday use. Developer documentation starts at
[docs/README.md](README.md).

## Connect

1. Click **New connection** (the `+` in the window header).
2. Pick the database type, then fill in host, port, database and user. For SQLite
   and DuckDB, choose the file.
3. Click **Test** to check the details, then **Connect**.

Passwords are kept in your desktop keyring, never in BookiE's own files.

- **SSH**: open the SSH section of the form to reach a database through one or
  more SSH hosts. BookiE asks before trusting a host key it has not seen.
- **TLS**: choose how strictly the server certificate is checked. "Verify full"
  checks both the certificate authority and the host name.
- **Environment and read-only**: mark a connection as production, staging or
  local, and tick **Read-only** to refuse every change on it.
- **Import from URL** fills the form from a connection URL such as
  `postgres://user@host:5432/db`.
- **Share connections**: export or import connections from the menu in the saved
  list. Give a passphrase to include saved passwords; without one, passwords stay
  behind.

## Browse a table

Click a table in the sidebar. The sidebar groups tables and views under each
schema; click a group to collapse it, and type in the search to find a table.

- **Edit**: double-click a cell, or press F2 or Enter. Changes stay pending
  (shown with a dot on the tab) until you press Ctrl+S. Ctrl+Z and Ctrl+Y undo
  and redo pending changes.
- **Insert and delete**: Ctrl+N inserts a row, Delete removes the selected rows.
  Ctrl+Shift+N sets the focused cell to NULL.
- **Filter and sort**: Ctrl+F opens the filter bar. Click a column header to
  sort. Right-click a cell and choose **Filter by This Value** for a quick filter.
- **Columns**: the **Columns…** entry in the cell menu hides or shows columns.
  Drag a header to reorder columns. Both are remembered per table.
- **Find**: Ctrl+Alt+F lists loaded rows that contain a text.
- **Long values**: cells longer than 8 KiB show the start of the value and its
  size. **View Value** opens the whole value; copy, export and edits always use
  the full value.
- **Row inspector**: shows every column of the selected row with its type.
- **Selection totals**: select several rows to see sums and averages of numeric
  columns in the selection badge tooltip.

## Run SQL

Ctrl+E opens a SQL editor tab for the current connection.

- Ctrl+Enter runs the whole script; Ctrl+Shift+Enter runs the statement under
  the cursor (shaded). Escape cancels a running query when the server supports
  it.
- A script shows one result per statement. More than five results collapse into
  a drop-down. **Pin results** keeps the current results above the next run.
- After a run, the gutter marks each statement with a tick or a cross.
- A failed statement shows the error, with **Copy error**, and on PostgreSQL the
  line and column of the error inside that statement.
- `:name` placeholders ask for values before the statement runs and send them as
  bound parameters, never pasted into the SQL.
- Completion offers tables after `FROM` and `JOIN` and columns elsewhere.
- **Session** keeps one connection for the tab, so settings, temporary tables and
  transactions carry over between runs.
- **Explain** shows the plan of the selected text, or of the whole editor when nothing is selected.
- Ctrl+H opens query history, Ctrl+D saves the query as a favorite, Ctrl+P opens
  Open Quickly for favorites, tabs and connections.

## Import and export

- **Export**: from a table or a result, choose CSV, JSON, Markdown, HTML, XML, SQL
  or an Excel workbook. For a table you can export the current page or every row.
- **Import**: right-click a table and choose **Import CSV…** to load a CSV file
  into it, or use the button on a schema header to create a new table from a CSV
  file. Separator, header row and column mapping are detected and can be changed.

## Safety

BookiE checks every statement before it runs:

- Writes on a read-only connection are refused.
- Depending on the connection's environment and your policy, risky statements
  (for example a `DELETE` without `WHERE`, or schema changes in production) ask
  for your approval first. The time spent waiting for approval is not counted in
  the statement's elapsed time.
- Every executed, refused or cancelled operation is written to an audit journal
  on your machine.

## Snapshots

Planned for a 0.2.x release, after 0.2.0: take a snapshot of a database before an
experiment and restore it with one click, starting with PostgreSQL. See
[ADR 0015](decisions/0015-database-snapshots.md) and ledger rows SNAP-1 to SNAP-4 in
[known-issues.md](known-issues.md).

## AI agents (MCP)

BookiE can let an AI assistant use your saved connections through the Model
Context Protocol. Open **Preferences → MCP** to create a token, choose which
connections it may use and which tools it may call. Every agent statement goes
through the same safety checks, and agent changes follow the approval rules of the connection's environment.
`bookie-agentd` runs the same server without the window, for headless use.

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
| F5 | Refresh the table |
| Ctrl+W | Close the tab |
