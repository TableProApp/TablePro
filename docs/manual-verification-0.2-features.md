# Manual verification: the 0.2 upstream feature sprint

The features below have logic tests. Four isolated GTK widget regressions passed
on 2026-09-26, including long-cell edit seeding; this does not qualify the full
installed workflows, layouts or light/dark appearance below. Unchecked items
remain pending.

Current target (2026-09-28): **Arch Linux / Omarchy / Hyprland, native Wayland**,
after the B3/B4 continuation tasks. Repeat applicable installed checks on GNOME
desktop under Debian Wayland immediately after the Arch pass; this phase is required. Use the [active sprint packets](bookie-0.2-sprint.md#arch--omarchy--wayland-ui-packets);
Xvfb success does not establish native Wayland behavior.

Record the full binary/package SHA, package checksum when installed, GTK backend,
OS/Hyprland/GTK/libadwaita versions, display scale, light/dark mode, result and
screenshot paths. Test both normal size and a narrow/resized window, keyboard
focus, clipboard and popover/dialog placement. Mark blocked and not-run items
explicitly. No boxes were checked by the September 28 documentation review.

Take light and dark screenshots for each section, per `AGENTS.md`. Record a result
beside each item rather than leaving it blank, because a blank line here reads as
"passed" to the next person.

Real values: before 0.2.0, also run the by-hand value check in [oracle review](oracle-review.md) (Part B), which compares each engine's own client with the grid, export and edit path.

Build first:

```bash
cd linux && cargo build -p tablepro-app
```

## Export dialog

Open a result, then Export Results.

- [ ] The Format list offers CSV, JSON, Markdown, HTML, XML, SQL and Excel.
- [ ] SQL is absent for a MongoDB or Redis connection, present for the others.
- [ ] The CSV options group shows for CSV and hides for every other format.
- [ ] A SQL options group with an editable Table name shows only for SQL.
- [ ] For a browse tab the Table name is prefilled `schema.table`; for an editor tab
      it is the tab label, and editing it changes the emitted statements.
- [ ] The written `.xlsx` opens in LibreOffice and the `.html` in a browser.
- [ ] Cancelling a large export leaves any existing destination file untouched.
- [ ] An Excel export above the sheet row limit is refused, and the message names
      the limit.

## CSV import

Right-click a table in the sidebar, then Import CSV. Separately, use the second
icon button in a schema header for Table from CSV.

- [ ] Separator and header-row detection are right for a comma file, a semicolon
      file, and a file with no header.
- [ ] The preview grid matches the file.
- [ ] Column mapping is prefilled sensibly and can be changed.
- [ ] Creating a table shows a name and an inferred type per column, both editable
      before anything runs.
- [ ] Approval is requested **once** for the whole import, not per batch.
- [ ] Progress advances and Cancel stops it.
- [ ] A file with a bad row partway through stops the import and the message says
      how many rows were written.
- [ ] Import refuses to start on a read-only connection.

## Connection dialog and browse shortcuts

- [ ] New connection defaults match the selected driver; no PostgreSQL defaults
      leak into another engine. Switching drivers and editing a saved connection
      preserves intended custom values.
- [ ] The current header title and grouped Test/Connect actions fit at narrow
      width in light and dark; the title does not overlap the actions.
- [ ] Enter submits the form and Escape dismisses without changing saved data.
- [ ] Browse shortcuts show the actual Left, Right, Space and pointer modifiers;
      keyboard and click actions match their labels.

## Connection list

- [ ] Connections are grouped, with one section per group and an ungrouped section.
- [ ] A group that appears twice in the ordering still renders one section.
- [ ] The colour swatch shows on a tagged row and the picker sets it.
- [ ] Duplicate produces a new row with a distinct name, and connecting to it asks
      for credentials rather than reusing the original's.
- [ ] The Name field in the connect dialog is used when set, and the derived
      `user@host` label still appears when it is blank.
- [ ] Two connections to the same endpoint stay separate after reconnecting to
      each. This is the regression the id-first identity change fixed.

## Long-query notice

- [ ] Run `SELECT pg_sleep(12)`, switch to another window: a "Query finished"
      notification appears when it ends. With the window focused, none appears.

## Per-connection timeouts

- [ ] The connect dialog shows Connect timeout and Query timeout rows; 0 means default.
- [ ] A connection saved with a 2-second query timeout stops `SELECT pg_sleep(5)` after
      about 2 seconds, while another connection still uses the Preferences timeout.
- [ ] A connect timeout of 3 seconds to an unreachable host fails after about 3 seconds.

## Connection bundles

- [ ] Export without a passphrase, then read the file: it contains hosts and
      usernames and **no** password, passphrase or token.
- [ ] Export with a passphrase, then import it on a second profile
      (`TABLEPRO_PROFILE=development`) and confirm the connections and their
      credentials arrive.
- [ ] A wrong passphrase and a file edited after export give the **same** message.
- [ ] Importing a bundle whose id already exists locally against a different server
      creates a new connection and leaves the local one untouched.
- [ ] The import plan lists every connection with its disposition and can be
      unticked before anything is written.

## Structure tab, column comments

- [ ] A Comment row appears per column on PostgreSQL, MySQL, SQL Server and
      ClickHouse.
- [ ] On ClickHouse the field is populated but not editable for an existing column,
      with a tooltip saying why.
- [ ] No Comment row appears on SQLite or DuckDB.
- [ ] Adding, editing and clearing a comment all save and survive a reload.
- [ ] Renaming a column and editing its comment in the same save works.

## Editor and history

- [ ] Ctrl+O opens a `.sql` file into a new tab titled with the file name.
- [ ] Typing marks the title with `•`; Ctrl+S saves, clears the mark and shows "Saved".
- [ ] Ctrl+S on an editor tab never opened from a file asks where to save.
- [ ] Ctrl+Shift+S saves to a new file and the tab then follows that file.
- [ ] Change the file in another editor, then press Ctrl+S: the "changed on disk"
      dialog appears. Cancel leaves both copies alone; Overwrite writes yours;
      Save As… writes elsewhere.
- [ ] Closing a tab with unsaved file changes asks Save/Discard/Cancel, and Save
      closes it only after the file is written.
- [ ] Saving a file that is a symlink updates its target and keeps the link.
- [ ] Restart with a file tab open: the tab is titled by the file again, unsaved
      edits still show `•`, and Ctrl+S saves to the same file.
- [ ] Delete that file, then restart: the tab keeps its text and a toast says it
      is no longer linked.
- [ ] Ctrl+S on a browse or structure tab still saves pending edits there.
- [ ] A `.sql` file above the size limit is refused with an explanation, not
      truncated.
- [ ] Ctrl+Shift+D lists saved queries; open, rename and delete all work.
- [ ] Saving a structure change or edited rows appears in history, and the history
      dialog can filter those out.
- [ ] `TABLEPRO_LOG_FORMAT=json ./target/debug/tablepro` writes lines that parse as
      JSON; unset keeps the human format.

## Built-in SSH host keys and tunnel loss

- [ ] A new host shows its fingerprint before trust; decline/cancel writes no key
      and opens no database connection. Explicit acceptance persists only that key.
- [ ] A changed key is refused. Reconnect never silently learns an unknown key.
- [ ] Bastion loss retires affected editor sessions and starts reconnect promptly;
      a result from the old session cannot replace current state.

## SSH agent (built-in client)

- [ ] Choose "SSH agent" in the SSH section with a key loaded in ssh-agent: the
      connection authenticates without a password or key file prompt.
- [ ] With the agent stopped, the error says the agent could not be reached.

## System OpenSSH tunnel

Build and install with the helper (`cargo build -p tablepro-ssh --bin tablepro-askpass`
beside the app binary, or an installed package).

- [ ] Turn on "Use system OpenSSH" in the SSH section and connect to a host
      already in `~/.ssh/known_hosts`: no prompt, the connection works.
- [ ] Connect to a new host: a "Trust this SSH host?" dialog shows the
      fingerprint; Cancel fails the connection and writes nothing.
- [ ] A host reached through a `ProxyJump` line in `~/.ssh/config` connects.
- [ ] A saved password is used for the target host; a jump host asking for a
      password gets a dialog instead of the saved one.
- [ ] A PostgreSQL connection with Verify Full through the OpenSSH tunnel
      verifies the database hostname.
- [ ] After closing the app, no `ssh -M` process is left running.

## Editor sessions (PostgreSQL, MySQL, SQL Server and SQLite files)

- [ ] Turn on Session in an editor tab: `SET search_path` and a `CREATE TEMP
      TABLE` from one run are still in effect on the next run.
- [ ] `BEGIN`, then an `UPDATE` in a later run: the button reads "Session ·
      transaction open"; another tab cannot see the change.
- [ ] Turning Session off with a transaction open asks Commit / Roll Back /
      Cancel, and each does what it says; Cancel leaves the session on.
- [ ] Closing the tab with a transaction open asks first; Roll Back and Close
      leaves the table unchanged.
- [ ] Without Session, a lone `BEGIN` is refused and the message mentions Session.
- [ ] On ClickHouse or an in-memory SQLite database, turning Session on explains that the engine does not
      offer it yet and the button turns back off.
- [ ] The audit journal shows the session's COMMIT or ROLLBACK against the same
      batch as the statements inside it.

## Session failure and shutdown paths (B4 I4)

- [ ] Stop appears only where server cancellation is supported; stopping a session
      query records the terminal outcome and permits later supported queries.
- [ ] A session timeout reports its actual cancelled/unknown state in the UI and
      audit; it does not present an ambiguous write as safely undone.
- [ ] Failed COMMIT after an aborted PostgreSQL transaction shows rollback; a
      deferred-constraint failure clears the transaction-open state and retry does
      not fabricate a second commit.
- [ ] Window close and Disconnect with an open transaction ask first, honor Cancel,
      and finish the chosen rollback/commit before teardown; verify persisted rows.
- [ ] A retired session turns its toggle off; late state messages cannot relabel a
      replacement session. Automatic reconnect retires the previous tab sessions.
- [ ] An unknown write outcome blocks only its owning connection; another connection
      stays usable. Restart/reconnect recovery follows the durable audit rules.
- [ ] `SET autocommit=0`, `SET IMPLICIT_TRANSACTIONS ON`, `XA START` and an
      unterminated transaction batch are refused on applicable shared connections.

## Filter by This Value

- [ ] Right-click a cell in a browsed table: Filter by This Value narrows the rows
      and the filter strip shows the new rule.
- [ ] On a NULL cell it filters with IS NULL.
- [ ] Doing it again on another value of the same column replaces that rule.
- [ ] A JSON or binary cell shows "Values of this type can't be used as a filter".
- [ ] The item is absent from SQL editor result grids.

## Catalog window

Main menu, then Catalog, on a PostgreSQL connection with a few objects of each kind.

- [ ] Each kind in the dropdown lists its objects with schema and detail.
- [ ] Typing a schema name and pressing Enter narrows the list; clearing it lists all.
- [ ] On SQLite or MySQL the status says the engine does not list that kind,
      not "Nothing of this kind was found".
- [ ] Switching kind quickly never shows the previous kind's rows under the new one.
- [ ] Closing the window mid-load leaves no error toast behind.

## Grid cell editing: long text and JSON

A text or JSON cell over 40,000 bytes shows a shortened value ending in
`… (+N more chars)`. Editing used to start from that shortened text; this is
now fixed (`FULL_EDIT_TEXT_SLOT` in `crates/app/src/ui/grid/display.rs`) and its
isolated GTK regression passed on 2026-09-26. The installed workflow remains open. Use a table with a `text` or `json` column
and insert one row with a value of at least 50,000 characters (for example
`SELECT repeat('a', 50000)` cast to the column's type, or a JSON array with
enough elements).

- [ ] The cell shows the shortened text ending in `… (+N more chars)`.
- [ ] Double-click the cell: the edit field's content is the **full** value,
      not the shortened one, and does not end in the `more chars` marker.
- [ ] Press Escape without typing anything: no edit is recorded (check the
      history dialog or the change-tracker highlight), and reopening the cell
      still shows the full value.
- [ ] Click away (focus-out) without typing anything: same as Escape, no edit
      recorded.
- [ ] Append one character at the end of the full value and commit (Enter or
      Tab): reload the row and confirm the saved value is the original text
      plus that one character, not the shortened text.
- [ ] For a JSON column, open the cell's JSON popover editor: its content is
      also the full value, not the shortened one. Save without changing
      anything, then Save after a small change, and confirm the same two
      outcomes as above.
- [ ] Do all of the above once more for a value just under 40,000 bytes (no
      truncation should ever have applied) to confirm normal editing still
      works unchanged.

## Server activity view: binary values

- [ ] Open a connection's activity/session view while a query on a `bytea` or
      `varbinary` column is visible. A binary value shows as `<N bytes>`, not
      as a value that reads like a hexadecimal escape (for example not
      `\x10 bytes`).

## Result headers, selection statistics, error copy and connection strip

- [ ] Browse a table: each column header shows its name, a key marker for
      primary and foreign keys, and the lower-case type beneath it, in light
      and dark.
- [ ] Select several rows of a numeric column: the selection badge tooltip
      lists the column's sum and average. A text column is not listed.
- [ ] Run a failing statement in the editor: Copy error places the exact error
      text on the clipboard.
- [ ] Tag a connection red and open it: the strip above the workspace tabs is
      red in light and dark. Change the tag: the strip follows without a restart.

## Sidebar tree

- [ ] On a PostgreSQL connection with two schemas, the sidebar shows each schema with Tables and Views groups and a count. Click a group: its objects hide and the chevron points right; click again to restore.
- [ ] Type in the sidebar search: groups holding a match open even if collapsed; clearing the search restores your collapsed groups. Quit and reopen the connection: the groups you collapsed are still collapsed.
- [ ] New Table and Table from CSV on a Tables group still open their dialogs for that schema. Light and dark look right.

## Pinned results and gutter marks

- [ ] Run `SELECT 1; SELECT 2;`, click Pin results, change the script and run it again: the first results stay as tabs marked 📌 ahead of the new ones. The button now reads Unpin results (2); clicking it drops the pinned tabs.
- [ ] After running a script, each statement's first line shows a tick or, for a failed statement, a cross in the gutter, in light and dark. Edit the script and run it again: the marks follow the new run.

## Carried over from the earlier sprint

- [ ] `cell_editor.rs`: in-place cell editing in light and dark. Held since the
      `OnceCell` removal.

## Known gaps that are not GTK

- Creating a table from a CSV file falls back to PostgreSQL-leaning type names on
  ClickHouse, MongoDB, Redis and DuckDB. Only PostgreSQL, MySQL, SQLite and SQL
  Server have real type-name tables, and none of the four fallback engines was
  exercised.
- Bundle export and import are covered at the byte level in unit tests and by the
  keyring tier, but no end-to-end round trip between two real profiles has been run.
- Bundle export and import write **no** audit-journal entries. `AuditEvent` is
  SQL-shaped and hash-chained, so an administrative-event class needs its own ADR
  before that gap can be closed. See `storage.md`.
- SQL-format export and copied INSERT statements now preserve binary values on
  PostgreSQL, MySQL, SQLite, SQL Server and ClickHouse, with real-engine tests
  for NULL, empty blobs and all 256 byte values. DuckDB binary SQL literals also have a
  NULL/empty/all-byte round-trip regression in the B3 ledger; installed acceptance
  is still pending. Other lossless-contract requirements
  remain under B3.
