# Manual verification: the 0.2 upstream feature sprint

The features below have logic tests. Four isolated GTK widget regressions passed on 2026-09-26, including long-cell edit seeding; this does not qualify the full installed workflows, layouts or light/dark appearance below. Unchecked items remain pending.

Current target (2026-09-28): **Arch Linux / Omarchy / Hyprland, native Wayland**, after the B3/B4 continuation tasks. Repeat applicable installed checks on GNOME desktop under Debian Wayland immediately after the Arch pass; this phase is required. Use the [active sprint packets](bookie-0.2-sprint.md#arch--omarchy--wayland-ui-packets); Xvfb success does not establish native Wayland behavior.

Record the full binary/package SHA, package checksum when installed, GTK backend, OS/Hyprland/GTK/libadwaita versions, display scale, light/dark mode, result and screenshot paths. Test both normal size and a narrow/resized window, keyboard focus, clipboard and popover/dialog placement. Mark blocked and not-run items explicitly. No boxes were checked by the September 28 documentation review.

Take light and dark screenshots for each section, per `AGENTS.md`. Record a result beside each item rather than leaving it blank, because a blank line here reads as "passed" to the next person.

Real values: before 0.2.0, also run the by-hand value check in [oracle review](oracle-review.md) (Part B), which compares each engine's own client with the grid, export and edit path.

## Installed run on 2026-10-12

Package `bookie 0.2.0-1`, built 2026-10-12 from the UX worktree at `d3202c17c` (BookiE `linux` `6cc8bd732` plus the [#618](https://github.com/cozyGarage/BookiE/pull/618) branch). `/usr/bin/bookie` SHA-256 `b2a8431bba1f4eddf4cc28a83110f789d38af75b16681152e2a5e837a35c3e87`. Arch Linux, Hyprland 0.56.2, native Wayland, GTK 4.22.4, libadwaita 1.9.3, GtkSourceView 5.20.0, scale 1, dark theme only. Databases: PostgreSQL 17 and MariaDB 11 in local containers. The UI was driven through AT-SPI, a virtual pointer and keyboard input; screenshots were kept locally and not committed.

The maintainer checked the same build by hand on 2026-10-12: dark and light themes both render, and the app follows the system theme when it changes. Results are written beside each item as "2026-10-12 Hyprland dark". Boxes stay unticked because the per-item light-theme pass, GNOME and narrow-width checks were not run. Items without a 2026-10-12 note were not run. Defects found in this run are [#648](https://github.com/cozyGarage/BookiE/issues/648) to [#660](https://github.com/cozyGarage/BookiE/issues/660) and [#662](https://github.com/cozyGarage/BookiE/issues/662); [#648](https://github.com/cozyGarage/BookiE/issues/648) aborts the app.

Build first:

```bash
cargo build -p tablepro-app
```

## Export dialog

Open a result, then Export Results.

- [ ] The Format list offers CSV, JSON, Markdown, HTML, XML, SQL and Excel. **2026-10-12 Hyprland dark:** passed.
- [ ] SQL is absent for a MongoDB or Redis connection, present for the others.
- [ ] The CSV options group shows for CSV and hides for every other format. **2026-10-12 Hyprland dark:** passed for CSV and SQL only.
- [ ] A SQL options group with an editable Table name shows only for SQL. **2026-10-12 Hyprland dark:** passed.
- [ ] For a browse tab the Table name is prefilled `schema.table`; for an editor tab it is the tab label, and editing it changes the emitted statements. **2026-10-12 Hyprland dark:** browse tab passed (prefilled `public.customers`, edited name reached the INSERT statements); editor tab not run. Export after a column rename used the old name, [#651](https://github.com/cozyGarage/BookiE/issues/651).
- [ ] The written `.xlsx` opens in LibreOffice and the `.html` in a browser.
- [ ] Cancelling a large export leaves any existing destination file untouched.
- [ ] An Excel export above the sheet row limit is refused, and the message names the limit.

## CSV import

Right-click a table in the sidebar, then Import CSV. Separately, use the second icon button in a schema header for Table from CSV.

- [ ] Separator and header-row detection are right for a comma file, a semicolon file, and a file with no header. **2026-10-12 Hyprland dark:** semicolon file with a header passed; comma and headerless files not run.
- [ ] The preview grid matches the file.
- [ ] Column mapping is prefilled sensibly and can be changed. **2026-10-12 Hyprland dark:** prefill passed on MariaDB (auto-increment `id` on Skip, `name` mapped); changing a mapping not run.
- [ ] For an existing table, remember a mapping, reorder the CSV headers, restore it, and confirm values still target the named columns; added destination columns remain on Skip.
- [ ] Duplicate CSV headers are distinguishable, and a saved mapping refuses to restore if its selected header or destination column is missing or ambiguous.
- [ ] A mapping saved for one connection, database, schema or table is not offered for another; Forget removes only the current table mapping.
- [ ] With the header-row option off, saving or restoring a mapping is refused. No CSV row values appear in the saved mapping file.
- [ ] For SQLite `id INTEGER PRIMARY KEY`, a CSV `id` header stays on Skip, explains that the database generates the value, and importing source IDs 51 and 52 stores generated IDs 1 and 2.
- [ ] Creating a table shows a name and an inferred type per column, both editable before anything runs.
- [ ] Approval is requested **once** for the whole import, not per batch.
- [ ] Progress advances and Cancel stops it. **2026-10-12 Hyprland dark:** failed. The rows were written but the progress dialog stayed at 2 of 2 and Cancel did not close it, [#655](https://github.com/cozyGarage/BookiE/issues/655).
- [ ] A file with a bad row partway through stops the import and the message says how many rows were written.
- [ ] Import refuses to start on a read-only connection.

## Connection dialog and browse shortcuts

- [ ] Screen readers can activate Driver, Endpoint and TLS, and announce Port, Connect timeout and Query timeout. GTK AT-SPI scenario passed in Xvfb on 2026-10-13; native Hyprland verification is pending. The sidebar search, saved-filter name and colour picker are outside this connection-form check, [#658](https://github.com/cozyGarage/BookiE/issues/658).
- [ ] New connection defaults match the selected driver; no PostgreSQL defaults leak into another engine. Switching drivers and editing a saved connection preserves intended custom values. **2026-10-12 Hyprland dark:** defaults passed for all seven drivers; switching drivers resets typed port, database and username, [#653](https://github.com/cozyGarage/BookiE/issues/653).
- [ ] For MySQL/MariaDB, select a local Unix socket and confirm the form shows a socket-file path while hiding host and port. Switch back to Network and confirm the socket path is hidden and host/port return.
- [ ] Connect through a real local MySQL/MariaDB socket, save the connection, reopen it, and confirm the socket path and endpoint mode remain selected. Export and re-import a bundle and confirm the same endpoint is retained.
- [ ] Confirm a missing or invalid socket path fails without attempting a TCP connection. Local sockets refuse TLS and SSH; existing PostgreSQL socket-directory and SSH-forwarded MySQL socket connections still work.
- [ ] The current header title and grouped Test/Connect actions fit at narrow width in light and dark; the title does not overlap the actions.
- [ ] Enter submits the form and Escape dismisses without changing saved data. **2026-10-12 Hyprland dark:** Enter failed, [#652](https://github.com/cozyGarage/BookiE/issues/652). The GTK regression now covers nested entry activation; rerun the keyboard flow on installed Wayland.
- [ ] Browse shortcuts show the actual Left, Right, Space and pointer modifiers; keyboard and click actions match their labels. **2026-10-12 Hyprland dark:** failed. The window is one column taller than the screen, pointer gestures have no key caps and rows repeat, [#662](https://github.com/cozyGarage/BookiE/issues/662).

## Connection list

- [ ] Connections are grouped, with one section per group and an ungrouped section.
- [ ] A group that appears twice in the ordering still renders one section.
- [ ] The colour swatch shows on a tagged row and the picker sets it. **2026-10-12 Hyprland dark:** the picker saved the colour; the swatch was not checked.
- [ ] With Orca, open Group and tags, navigate to Colour, open the named button, choose a palette colour, and confirm the selected colour is announced and saved. Sidebar table search and the saved-filter name field announce their purpose. Native Wayland screen-reader check pending.
- [ ] Duplicate produces a new row with a distinct name, and connecting to it asks for credentials rather than reusing the original's. **2026-10-12 Hyprland dark:** distinct name passed ("(copy)"); the copy did not reuse the password but did not ask for one either, it failed and offered Edit Connection, [#660](https://github.com/cozyGarage/BookiE/issues/660).
- [ ] The Name field in the connect dialog is used when set, and the derived `user@host` label still appears when it is blank.
- [ ] Two connections to the same endpoint stay separate after reconnecting to each. This is the regression the id-first identity change fixed.
- [ ] On PostgreSQL, right-click a schema and hide it. Confirm its tables and views disappear, search cannot reveal them, the filter menu can restore one or all schemas, and each connection retains its own hidden-schema list after reconnecting. **2026-10-12 Hyprland dark:** hide, search and restore one schema passed; per-connection retention after reconnect not run.

## Long-query notice

- [ ] Run `SELECT pg_sleep(12)`, switch to another window: a "Query finished" notification appears when it ends. With the window focused, none appears. **2026-10-12 Hyprland dark:** the unfocused case passed ("Query finished", 12 seconds); the focused case not run.

## Per-connection timeouts

- [ ] The connect dialog shows Connect timeout and Query timeout rows; 0 means default. **2026-10-12 Hyprland dark:** passed.
- [ ] A connection saved with a 2-second query timeout stops `SELECT pg_sleep(5)` after about 2 seconds, while another connection still uses the Preferences timeout. **2026-10-12 Hyprland dark:** stopped after 2.007 s, passed; the message names Preferences instead of the connection, [#654](https://github.com/cozyGarage/BookiE/issues/654). The second connection not run.
- [ ] A connect timeout of 3 seconds to an unreachable host fails after about 3 seconds.

## Connection bundles

- [ ] Export without a passphrase, then read the file: it contains hosts and usernames and **no** password, passphrase or token.
- [ ] Export with a passphrase, then import it on a second profile (`TABLEPRO_PROFILE=development`) and confirm the connections and their credentials arrive.
- [ ] A wrong passphrase and a file edited after export give the **same** message.
- [ ] Importing a bundle whose id already exists locally against a different server creates a new connection and leaves the local one untouched.
- [ ] The import plan lists every connection with its disposition and can be unticked before anything is written.

## Structure tab, column comments

- [ ] A Comment row appears per column on PostgreSQL, MySQL, SQL Server and ClickHouse. **2026-10-12 Hyprland dark:** PostgreSQL passed; others not run.
- [ ] On ClickHouse the field is populated but not editable for an existing column, with a tooltip saying why.
- [ ] No Comment row appears on SQLite or DuckDB.
- [ ] Adding, editing and clearing a comment all save and survive a reload. **2026-10-12 Hyprland dark:** editing and clearing passed on PostgreSQL (checked in the database); adding not run.
- [ ] Renaming a column and editing its comment in the same save works. **2026-10-12 Hyprland dark:** passed on PostgreSQL.

## Editor and history

- [ ] Toggle **Split** on and off with the mouse and keyboard; edit the query from either pane, confirm both views update, and check that each pane keeps its scroll position at a narrow window width. **2026-10-12 Hyprland dark:** mouse toggle and shared buffer passed; keyboard and narrow width not run. Split on an orphaned tab aborts the app, [#648](https://github.com/cozyGarage/BookiE/issues/648).
- [ ] Ctrl+O opens a `.sql` file into a new tab titled with the file name. **2026-10-12 Hyprland dark:** passed.
- [ ] Typing marks the title with `•`; Ctrl+S saves, clears the mark and shows "Saved". **2026-10-12 Hyprland dark:** passed.
- [ ] Ctrl+S on an editor tab never opened from a file asks where to save.
- [ ] Ctrl+Shift+S saves to a new file and the tab then follows that file.
- [ ] Change the file in another editor, then press Ctrl+S: the "changed on disk" dialog appears. Cancel leaves both copies alone; Overwrite writes yours; Save As… writes elsewhere. **2026-10-12 Hyprland dark:** Cancel and Overwrite passed; Save As not run.
- [ ] Closing a tab with unsaved file changes asks Save/Discard/Cancel, and Save closes it only after the file is written. **2026-10-12 Hyprland dark:** the prompt passed; Save wrote the file but the tab stayed open, [#648](https://github.com/cozyGarage/BookiE/issues/648).
- [ ] Saving a file that is a symlink updates its target and keeps the link.
- [ ] Restart with a file tab open: the tab is titled by the file again, unsaved edits still show `•`, and Ctrl+S saves to the same file.
- [ ] Delete that file, then restart: the tab keeps its text and a toast says it is no longer linked.
- [ ] Ctrl+S on a browse or structure tab still saves pending edits there.
- [ ] A `.sql` file above the size limit is refused with an explanation, not truncated.
- [ ] Ctrl+Shift+D lists saved queries; open, rename and delete all work.
- [ ] Saving a structure change or edited rows appears in history, and the history dialog can filter those out.
- [ ] `TABLEPRO_LOG_FORMAT=json ./target/debug/tablepro` writes lines that parse as JSON; unset keeps the human format.

## Built-in SSH host keys and tunnel loss

- [ ] A new host shows its fingerprint before trust; decline/cancel writes no key and opens no database connection. Explicit acceptance persists only that key.
- [ ] A changed key is refused. Reconnect never silently learns an unknown key.
- [ ] Bastion loss retires affected editor sessions and starts reconnect promptly; a result from the old session cannot replace current state.

## SSH agent (built-in client)

- [ ] Choose "SSH agent" in the SSH section with a key loaded in ssh-agent: the connection authenticates without a password or key file prompt.
- [ ] With the agent stopped, the error says the agent could not be reached.

## System OpenSSH tunnel

Build and install with the helper (`cargo build -p tablepro-ssh --bin tablepro-askpass` beside the app binary, or an installed package).

- [ ] Turn on "Use system OpenSSH" in the SSH section and connect to a host already in `~/.ssh/known_hosts`: no prompt, the connection works.
- [ ] Connect to a new host: a "Trust this SSH host?" dialog shows the fingerprint; Cancel fails the connection and writes nothing.
- [ ] A host reached through a `ProxyJump` line in `~/.ssh/config` connects.
- [ ] A saved password is used for the target host; a jump host asking for a password gets a dialog instead of the saved one.
- [ ] A PostgreSQL connection with Verify Full through the OpenSSH tunnel verifies the database hostname.
- [ ] After closing the app, no `ssh -M` process is left running.

## Editor sessions (PostgreSQL, MySQL, SQL Server and SQLite files)

- [ ] Turn on Session in an editor tab: `SET search_path` and a `CREATE TEMP TABLE` from one run are still in effect on the next run.
- [ ] `BEGIN`, then an `UPDATE` in a later run: the button reads "Session · transaction open"; another tab cannot see the change. **2026-10-12 Hyprland dark:** passed (label read "Session · transaction open"; a separate psql session did not see the change).
- [ ] Turning Session off with a transaction open asks Commit / Roll Back / Cancel, and each does what it says; Cancel leaves the session on. **2026-10-12 Hyprland dark:** Cancel and Commit passed; Roll Back not run.
- [ ] Closing the tab with a transaction open asks first; Roll Back and Close leaves the table unchanged.
- [ ] Without Session, a lone `BEGIN` is refused and the message mentions Session. **2026-10-12 Hyprland dark:** passed.
- [ ] On ClickHouse or an in-memory SQLite database, turning Session on explains that the engine does not offer it yet and the button turns back off.
- [ ] The audit journal shows the session's COMMIT or ROLLBACK against the same batch as the statements inside it. **2026-10-12 Hyprland dark:** COMMIT passed (same `batch_id` as the UPDATE).

## Session failure and shutdown paths (B4 I4)

- [ ] Stop appears only where server cancellation is supported; stopping a session query records the terminal outcome and permits later supported queries.
- [ ] A session timeout reports its actual cancelled/unknown state in the UI and audit; it does not present an ambiguous write as safely undone.
- [ ] Failed COMMIT after an aborted PostgreSQL transaction shows rollback; a deferred-constraint failure clears the transaction-open state and retry does not fabricate a second commit.
- [ ] Window close and Disconnect with an open transaction ask first, honor Cancel, and finish the chosen rollback/commit before teardown; verify persisted rows.
- [ ] A retired session turns its toggle off; late state messages cannot relabel a replacement session. Automatic reconnect retires the previous tab sessions.
- [ ] An unknown write outcome blocks only its owning connection; another connection stays usable. Restart/reconnect recovery follows the durable audit rules.
- [ ] `SET autocommit=0`, `SET IMPLICIT_TRANSACTIONS ON`, `XA START` and an unterminated transaction batch are refused on applicable shared connections.

## ENUM and SET pickers (PostgreSQL, MySQL and MariaDB)

- [ ] Double-click an ENUM cell: a list of the declared members opens with the current one highlighted; choosing another shows a pending change and Save writes that member. **2026-10-12 Hyprland dark:** passed on PostgreSQL; the keyboard highlight starts on the first member, [#660](https://github.com/cozyGarage/BookiE/issues/660).
- [ ] Choose the (empty) member of an ENUM that declares one: the cell shows empty and the stored value is the empty string, not NULL.
- [ ] Double-click a SET cell: each member has a check; toggling and pressing Apply writes the members in declared order; with none checked the stored value is the empty set, not NULL. **2026-10-12 Hyprland dark:** declared order passed on MariaDB (`red,green,blue`); the empty set not run. The popover clips its labels, [#657](https://github.com/cozyGarage/BookiE/issues/657).
- [ ] Set to NULL from the cell menu still works on a nullable ENUM or SET.
- [ ] On PostgreSQL, an enum column offers its labels in declared order; a column of an enum array type still opens the text editor.

## Paste into cells

- [ ] Copy a 2 by 2 block from a spreadsheet, click a cell in a browsed table with at least two rows and columns below and right of it, press Ctrl+V: four cells show as pending changes and the unsaved-change count reads 4. **2026-10-12 Hyprland dark:** passed.
- [ ] Paste a block that runs past the last loaded row or column: a toast says so and nothing changes. **2026-10-12 Hyprland dark:** passed for the last column; the last row is covered by the installed GTK scenario `paste_past_the_loaded_rows_changes_nothing`.
- [ ] Paste a value that does not parse for its column type: a toast names the column and row and nothing changes. **2026-10-12 Hyprland dark:** passed.
- [ ] Paste with no cell focused: a toast asks you to click a cell first.

## Explain tree

- [ ] On PostgreSQL, Explain a join: the dialog opens on a Tree tab with nested steps, a cost bar per step and the filter or condition lines under their step; the Text tab shows the raw plan. **2026-10-12 Hyprland dark:** tree, cost bars and condition lines passed; the Text tab not checked. The Tree and Text switcher shows missing icons, [#656](https://github.com/cozyGarage/BookiE/issues/656).
- [ ] On SQLite, Explain a query that scans and searches: steps nest by their parent.
- [ ] On MySQL, ClickHouse or DuckDB the dialog shows the text plan with no Tree tab.
- [ ] Explain on an empty editor still shows the existing message.

## Go to Referenced Row

- [ ] In a table with a foreign key, right-click a non-empty value in the key column: Go to Referenced Row opens the referenced table with one filter rule on the referenced column. **2026-10-12 Hyprland dark:** failed. The item is greyed out on a real foreign key, [#649](https://github.com/cozyGarage/BookiE/issues/649).
- [ ] On a cell of a column that is not a foreign key, or on a NULL key, the item is greyed out.
- [ ] With the referenced table already open, the same action switches to that tab and replaces its filter.
- [ ] A composite key filters every referenced column from the same row; with one of its columns hidden, a toast says so.

## Filter by This Value

- [ ] Right-click a cell in a browsed table: Filter by This Value narrows the rows and the filter strip shows the new rule. **2026-10-12 Hyprland dark:** passed; also covered by the installed GTK scenario `filter_by_this_value_narrows_the_browse_rows`. The filter strip opens with the rule editor collapsed, [#660](https://github.com/cozyGarage/BookiE/issues/660).
- [ ] On a NULL cell it filters with IS NULL.
- [ ] Doing it again on another value of the same column replaces that rule.
- [ ] A JSON or binary cell shows "Values of this type can't be used as a filter". **2026-10-12 Hyprland dark:** JSON passed; binary not run.
- [ ] The item is absent from SQL editor result grids.

## Named browse filters

- [ ] On one table, build and apply two structured filters, save them under different names, and switch between them without editing the rules. **2026-10-12 Hyprland dark:** passed.
- [ ] Rename one preset and delete the other; restart BookiE and confirm the renamed preset remains scoped to the same connection, schema and table. **2026-10-12 Hyprland dark:** passed.
- [ ] Save a preset with raw SQL, an empty name, an overlong name and beyond the per-table limit; each is refused with a useful message. **2026-10-12 Hyprland dark:** raw SQL and empty name refused; the name field stops at 48 characters; the per-table limit not run.
- [ ] Open the preset on a table whose columns changed; the invalid saved rule is not applied silently.

## Catalog window

Main menu, then Catalog, on a PostgreSQL connection with a few objects of each kind.

- [ ] Each kind in the dropdown lists its objects with schema and detail. **2026-10-12 Hyprland dark:** functions, triggers and sequences passed; other kinds not run.
- [ ] Typing a schema name and pressing Enter narrows the list; clearing it lists all. **2026-10-12 Hyprland dark:** passed.
- [ ] On SQLite or MySQL the status says the engine does not list that kind, not "Nothing of this kind was found".
- [ ] Switching kind quickly never shows the previous kind's rows under the new one.
- [ ] Closing the window mid-load leaves no error toast behind.

## Grid cell editing: long text and JSON

A text or JSON cell over 8 KiB shows the start of the value and `… (N bytes total)`. Editing used to start from that shortened text; this is now fixed (`FULL_EDIT_TEXT_SLOT` in `apps/linux/app/src/ui/grid/display.rs`) and its isolated GTK regression passed on 2026-09-26. The installed workflow remains open. Use a table with a `text` or `json` column and insert one row with a value of at least 50,000 characters (for example `SELECT repeat('a', 50000)` cast to the column's type, or a JSON array with enough elements).

- [ ] The cell shows the shortened text ending in `… (+N more chars)`. **2026-10-12 Hyprland dark:** the marker is now `… (N bytes total)`, and the cell offers only View Value, not editing, [#659](https://github.com/cozyGarage/BookiE/issues/659). The rest of this section was not run.
- [ ] Double-click the cell: the edit field's content is the **full** value, not the shortened one, and does not end in the `more chars` marker. Blocked until [#610](https://github.com/cozyGarage/BookiE/issues/610): previewed values are read-only in the grid today ([#659](https://github.com/cozyGarage/BookiE/issues/659)), so the editing items below cannot be run.
- [ ] Press Escape without typing anything: no edit is recorded (check the history dialog or the change-tracker highlight), and reopening the cell still shows the full value.
- [ ] Click away (focus-out) without typing anything: same as Escape, no edit recorded.
- [ ] Append one character at the end of the full value and commit (Enter or Tab): reload the row and confirm the saved value is the original text plus that one character, not the shortened text.
- [ ] For a JSON column, open the cell's JSON popover editor: its content is also the full value, not the shortened one. Save without changing anything, then Save after a small change, and confirm the same two outcomes as above.
- [ ] Do all of the above once more for a value just under 40,000 bytes (no truncation should ever have applied) to confirm normal editing still works unchanged.

## Server activity view: binary values

- [ ] Open a connection's activity/session view while a query on a `bytea` or `varbinary` column is visible. A binary value shows as `<N bytes>`, not as a value that reads like a hexadecimal escape (for example not `\x10 bytes`).

## Result headers, selection statistics, error copy and connection strip

- [ ] Browse a table: each column header shows its name, a key marker for primary and foreign keys, and the lower-case type beneath it, in light and dark. **2026-10-12 Hyprland dark:** name and type passed; key markers missing, [#649](https://github.com/cozyGarage/BookiE/issues/649).
- [ ] Select several rows of a numeric column: the selection badge popover lists the column's count, sum, average, min and max, and Copy summary copies them. A text column is not listed. **2026-10-12 Hyprland dark:** passed; also covered by the installed GTK scenario `selection_statistics_summarise_the_selected_rows`.
- [ ] Run a failing statement in the editor: Copy error places the exact error text on the clipboard. **2026-10-12 Hyprland dark:** passed.
- [ ] Tag a connection red and open it: the strip above the workspace tabs is red in light and dark. Change the tag: the strip follows without a restart. **2026-10-12 Hyprland dark:** failed before the direct tab-bar targeting fix; installed-package retest remains pending, [#650](https://github.com/cozyGarage/BookiE/issues/650).

## Sidebar tree

- [ ] On a PostgreSQL connection with two schemas, the sidebar shows each schema with Tables and Views groups and a count. Click a group: its objects hide and the chevron points right; click again to restore. **2026-10-12 Hyprland dark:** groups and counts passed; collapsing not run.
- [ ] Type in the sidebar search: groups holding a match open even if collapsed; clearing the search restores your collapsed groups. Quit and reopen the connection: the groups you collapsed are still collapsed.
- [ ] New Table and Table from CSV on a Tables group still open their dialogs for that schema. Light and dark look right.

## SQL code folding

- [ ] Place the cursor inside a multiline CASE block and press Ctrl+Shift+[. The block body folds and its opening and closing lines remain visible.
- [ ] Click the fold marker in the gutter. The body returns without changing the query text.
- [ ] Fold two blocks, then use Unfold all and Ctrl+Shift+]. Both show the complete query.
- [ ] Edit the query while a block is folded. The editor reveals the full query and clears stale fold markers.

## Pinned results and gutter marks

- [ ] Run `SELECT 1; SELECT 2;`, click Pin results, change the script and run it again: the first results stay as tabs marked 📌 ahead of the new ones. The button now reads Unpin results (2); clicking it drops the pinned tabs. **2026-10-12 Hyprland dark:** passed; also covered by the installed GTK scenario `pinned_results_stay_ahead_of_the_next_run`. Statement numbers continue after the pinned tabs, [#660](https://github.com/cozyGarage/BookiE/issues/660).
- [ ] After running a script, each statement's first line shows a tick or, for a failed statement, a cross in the gutter, in light and dark. Edit the script and run it again: the marks follow the new run. **2026-10-12 Hyprland dark:** dark theme passed.

## Carried over from the earlier sprint

- [ ] `cell_editor.rs`: in-place cell editing in light and dark. Held since the `OnceCell` removal.

## Known gaps that are not GTK

- Creating a table from a CSV file falls back to PostgreSQL-leaning type names on ClickHouse, MongoDB, Redis and DuckDB. Only PostgreSQL, MySQL, SQLite and SQL Server have real type-name tables, and none of the four fallback engines was exercised.
- Bundle export and import are covered at the byte level in unit tests and by the keyring tier, but no end-to-end round trip between two real profiles has been run.
- Bundle export and import write administrative audit events. Run a bundle round trip and confirm both events appear in `audit.jsonl` (B4-22).
- SQL-format export and copied INSERT statements now preserve binary values on PostgreSQL, MySQL, SQLite, SQL Server and ClickHouse, with real-engine tests for NULL, empty blobs and all 256 byte values. DuckDB binary SQL literals also have a NULL/empty/all-byte round-trip regression in the B3 ledger; installed acceptance is still pending. Other lossless-contract requirements remain under B3.
