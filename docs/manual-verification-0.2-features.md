# Manual verification: 0.2.0 features

This checklist records manual acceptance for the 0.2.0 target. GTK unit and widget tests do not qualify installed workflows, layouts or light/dark appearance. An unchecked item remains pending; a failure recorded from an earlier run is historical and must be rerun after its fix.

The 0.2.0 desktop target is **Arch Linux / Omarchy / Hyprland, native Wayland**. Debian and Ubuntu GNOME desktop acceptance follows 0.2.0 and is tracked under PKG-2. Use the [active sprint packets](bookie-0.2-sprint.md#arch--omarchy--wayland-ui-packets); Xvfb success does not establish native Wayland behavior.

Record the full binary/package SHA, package checksum when installed, GTK backend, OS/Hyprland/GTK/libadwaita versions, display scale, light/dark mode, result and screenshot paths. Test both normal size and a narrow/resized window, keyboard focus, clipboard and popover/dialog placement. Mark blocked and not-run items explicitly.

Take light and dark screenshots for each section, per `AGENTS.md`. Record a result beside each item rather than leaving it blank, because a blank line here reads as "passed" to the next person.

Real values: before 0.2.0, also run the by-hand value check in [oracle review](oracle-review.md) (Part B), which compares each engine's own client with the grid, export and edit path.

## Installed run on 2026-10-12

Package `bookie 0.2.0-1`, built 2026-10-12 from the UX worktree at `d3202c17c` (BookiE `linux` `6cc8bd732` plus the [#618](https://github.com/cozyGarage/BookiE/pull/618) branch). `/usr/bin/bookie` SHA-256 `b2a8431bba1f4eddf4cc28a83110f789d38af75b16681152e2a5e837a35c3e87`. Arch Linux, Hyprland 0.56.2, native Wayland, GTK 4.22.4, libadwaita 1.9.3, GtkSourceView 5.20.0, scale 1, dark theme only. Databases: PostgreSQL 17 and MariaDB 11 in local containers. The UI was driven through AT-SPI, a virtual pointer and keyboard input; screenshots were kept locally and not committed.

The maintainer checked the same build by hand on 2026-10-12: dark and light themes both render, and the app follows the system theme when it changes. Results are written beside each item as "2026-10-12 Hyprland dark". Boxes stay unticked because the per-item light-theme pass, GNOME and narrow-width checks were not run. Items without a 2026-10-12 note were not run. Defects found in this run are [#648](https://github.com/cozyGarage/BookiE/issues/648) to [#660](https://github.com/cozyGarage/BookiE/issues/660) and [#662](https://github.com/cozyGarage/BookiE/issues/662); the editor close defect was fixed in [#667](https://github.com/cozyGarage/BookiE/pull/667) and the shortcut window was updated in [#725](https://github.com/cozyGarage/BookiE/pull/725). Treat these run notes as historical; current retest status is written beside each item.

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
- [ ] For a browse tab the Table name is prefilled `schema.table`; for an editor tab it is the tab label, and editing it changes the emitted statements. **2026-10-12 Hyprland dark:** browse tab passed (prefilled `public.customers`, edited name reached the INSERT statements); editor tab not run. Export after a column rename used the old name; fixed by [#676](https://github.com/cozyGarage/BookiE/pull/676), installed retest pending.
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
- [ ] New connection defaults match the selected driver; no PostgreSQL defaults leak into another engine. Switching drivers and editing a saved connection preserves intended custom values. **2026-10-12 historical run:** defaults passed for all seven drivers; switching drivers reset custom port, database and username values. Fixed by [#740](https://github.com/cozyGarage/BookiE/pull/740); transition tests cover all three fields, and installed Hyprland retest remains pending.
- [ ] For MySQL/MariaDB, select a local Unix socket and confirm the form shows a socket-file path while hiding host and port. Switch back to Network and confirm the socket path is hidden and host/port return.
- [ ] Connect through a real local MySQL/MariaDB socket, save the connection, reopen it, and confirm the socket path and endpoint mode remain selected. Export and re-import a bundle and confirm the same endpoint is retained.
- [ ] Confirm a missing or invalid socket path fails without attempting a TCP connection. Local sockets refuse TLS and SSH; existing PostgreSQL socket-directory and SSH-forwarded MySQL socket connections still work.
- [ ] The current header title and grouped Test/Connect actions fit at narrow width in light and dark; the title does not overlap the actions.
- [ ] Enter submits the form and Escape dismisses without changing saved data. **2026-10-12 Hyprland dark:** Enter failed; fixed by [#737](https://github.com/cozyGarage/BookiE/pull/737). The GTK regression covers nested entry activation; rerun the keyboard flow on installed Wayland.
- [ ] Browse shortcuts show the actual Left, Right, Space and pointer modifiers; keyboard and click actions match their labels. **2026-10-12 Hyprland dark:** failed before the shortcut window was reorganized in [#725](https://github.com/cozyGarage/BookiE/pull/725); installed retest pending.

## Connection list

- [ ] Connections are grouped, with one section per group and an ungrouped section.
- [ ] A group that appears twice in the ordering still renders one section.
- [ ] The colour swatch shows on a tagged row and the picker sets it. **2026-10-12 Hyprland dark:** the picker saved the colour; the swatch was not checked.
- [ ] After connecting to a tagged connection, the workspace tab strip shows its colour. Changing or clearing the tag updates the strip, and disconnecting clears it. The GTK regression passes; the installed retest after [#768](https://github.com/cozyGarage/BookiE/pull/768) is pending.
- [ ] With Orca, open Group and tags, navigate to Colour, open the named button, choose a palette colour, and confirm the selected colour is announced and saved. Sidebar table search and the saved-filter name field announce their purpose. Native Wayland screen-reader check pending.
- [ ] Duplicate produces a new row with a distinct name. When the source has a saved database password, the copy's credential form opens with an empty password field; save a new password and verify both connections work independently. **2026-10-12 historical run:** distinct name passed ("(copy)"); the copy did not reuse the password but did not ask for one either, it failed and offered Edit Connection. Fixed in [#823](https://github.com/cozyGarage/BookiE/pull/823); installed retest pending ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
- [ ] The Name field in the connect dialog is used when set, and the derived `user@host` label still appears when it is blank.
- [ ] Two connections to the same endpoint stay separate after reconnecting to each. This is the regression the id-first identity change fixed.
- [ ] On PostgreSQL, right-click a schema and hide it. Confirm its tables and views disappear, search cannot reveal them, the filter menu can restore one or all schemas, and each connection retains its own hidden-schema list after reconnecting. **2026-10-12 Hyprland dark:** hide, search and restore one schema passed; per-connection retention after reconnect not run.

## Long-query notice

- [ ] Run `SELECT pg_sleep(12)`, switch to another window: a "Query finished" notification appears when it ends. With the window focused, none appears. **2026-10-12 Hyprland dark:** the unfocused case passed ("Query finished", 12 seconds); the focused case not run.

## Per-connection timeouts

- [ ] The connect dialog shows Connect timeout and Query timeout rows; 0 means default. **2026-10-12 Hyprland dark:** passed.
- [ ] A connection saved with a 2-second query timeout stops `SELECT pg_sleep(5)` after about 2 seconds, while another connection still uses the Preferences timeout. **2026-10-12 Hyprland dark:** stopped after 2.007 s, passed; the wording was fixed by [#668](https://github.com/cozyGarage/BookiE/pull/668). The second connection and installed retest remain pending.
- [ ] A connect timeout of 3 seconds to an unreachable host fails after about 3 seconds.

## Connection bundles

- [ ] Export without a passphrase, then read the file: it contains hosts and usernames and **no** password, passphrase or token.
- [ ] Export with a passphrase, then import it on a second profile (`TABLEPRO_PROFILE=development`) and confirm the connections and their credentials arrive.
- [ ] A wrong passphrase and a file edited after export give the **same** message.
- [ ] Importing a bundle whose id already exists locally against a different server creates a new connection and leaves the local one untouched.
- [ ] The import plan lists every connection with its disposition and can be unticked before anything is written.

## Structure tab, column comments

- [ ] Open an existing Structure tab and make an unsaved change: its title keeps the `· Structure` suffix alongside the dirty marker. The regression test in [#796](https://github.com/cozyGarage/BookiE/pull/796) covers title state; installed Wayland retest pending.
- [ ] A Comment row appears per column on PostgreSQL, MySQL, SQL Server and ClickHouse. **2026-10-12 Hyprland dark:** PostgreSQL passed; others not run.
- [ ] On ClickHouse the field is populated but not editable for an existing column, with a tooltip saying why.
- [ ] No Comment row appears on SQLite or DuckDB.
- [ ] Adding, editing and clearing a comment all save and survive a reload. **2026-10-12 Hyprland dark:** editing and clearing passed on PostgreSQL (checked in the database); adding not run.
- [ ] Renaming a column and editing its comment in the same save works. **2026-10-12 Hyprland dark:** passed on PostgreSQL.

## Editor and history

- [ ] Toggle **Split** on and off with the mouse and keyboard; edit the query from either pane, confirm both views update, and check that each pane keeps its scroll position at a narrow window width. **2026-10-12 Hyprland dark:** mouse toggle and shared buffer passed; keyboard and narrow width not run. The orphaned-tab abort was fixed by [#667](https://github.com/cozyGarage/BookiE/pull/667); repeat the installed flow.
- [ ] Ctrl+O opens a `.sql` file into a new tab titled with the file name. **2026-10-12 Hyprland dark:** passed.
- [ ] Typing marks the title with `•`; Ctrl+S saves, clears the mark and shows "Saved". **2026-10-12 Hyprland dark:** passed.
- [ ] Ctrl+S on an editor tab never opened from a file asks where to save.
- [ ] Ctrl+Shift+S saves to a new file and the tab then follows that file.
- [ ] Change the file in another editor, then press Ctrl+S: the "changed on disk" dialog appears. Cancel leaves both copies alone; Overwrite writes yours; Save As… writes elsewhere. **2026-10-12 Hyprland dark:** Cancel and Overwrite passed; Save As not run.
- [ ] Closing a tab with unsaved file changes asks Save/Discard/Cancel, and Save closes it only after the file is written. **2026-10-12 Hyprland dark:** the prompt passed; Save wrote the file but the tab stayed open. Fixed by [#667](https://github.com/cozyGarage/BookiE/pull/667); installed retest pending.
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
- [ ] Press Escape while the Explain plan dialog is open: the dialog closes. The installed GTK scenario `explain_plan_window_closes_on_escape` covers this behavior ([#781](https://github.com/cozyGarage/BookiE/pull/781)); installed Wayland retest pending.
- [ ] On SQLite, Explain a query that scans and searches: steps nest by their parent.
- [ ] On MySQL, ClickHouse or DuckDB the dialog shows the text plan with no Tree tab.
- [ ] Explain on an empty editor still shows the existing message.

## Go to Referenced Row

- [ ] In a table with a foreign key, right-click a non-empty value in the key column: Go to Referenced Row opens the referenced table with one filter rule on the referenced column. **2026-10-12 Hyprland dark:** failed because foreign keys arrived after the grid was drawn; fixed by [#664](https://github.com/cozyGarage/BookiE/pull/664). Installed retest pending.
- [ ] On a cell of a column that is not a foreign key, or on a NULL key, the item is greyed out.
- [ ] With the referenced table already open, the same action switches to that tab and replaces its filter.
- [ ] A composite key filters every referenced column from the same row; with one of its columns hidden, a toast says so.

## Filter by This Value

- [ ] Right-click a cell in a browsed table: Filter by This Value narrows the rows and the filter strip shows the new rule. **2026-10-12 historical run:** filtering passed, but the rule editor opened collapsed; fixed by [#820](https://github.com/cozyGarage/BookiE/pull/820). The installed GTK scenario `filter_by_this_value_narrows_the_browse_rows` covers the filter action; installed retest of the expanded editor is pending ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
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

## Grid previews for long values

In browse and SQL result grids, text, JSON and binary cells over 8 KiB show a typed preview with the original byte count. Previewed cells are read-only; **View Value** and **Copy Value** expose the complete value. Full-value editing is future work under [#610](https://github.com/cozyGarage/BookiE/issues/610). Use text and JSON values just below and just above the 8 KiB threshold.

- [ ] A value below the threshold displays in full and remains editable where that type supports grid edits.
- [ ] Values over the threshold show a prefix and `… (N bytes total)`, and the cell does not offer inline editing.
- [ ] View Value shows the complete text or JSON, including the final characters or JSON structure.
- [ ] A long unbroken value wraps without display-only hyphens; the GTK widget regression covers this rendering property ([#791](https://github.com/cozyGarage/BookiE/pull/791)); installed retest pending.
- [ ] Copy Value copies the complete text or JSON rather than the displayed preview.
- [ ] Repeat with a binary value over the threshold; the preview reports the original byte count and View Value exposes the full bytes.

## Server activity view: binary values

- [ ] Open a connection's activity/session view while a query on a `bytea` or `varbinary` column is visible. A binary value shows as `<N bytes>`, not as a value that reads like a hexadecimal escape (for example not `\x10 bytes`).

## Result headers, selection statistics, error copy and connection strip

- [ ] Browse a table: each column header shows its name, a key marker for primary and foreign keys, and the lower-case type beneath it, in light and dark. **2026-10-12 Hyprland dark:** name and type passed; key markers were missing before [#664](https://github.com/cozyGarage/BookiE/pull/664). Installed retest pending.
- [ ] Select several rows of a numeric column: the selection badge popover lists the column's count, sum, average, min and max, and Copy summary copies them. A text column is not listed. **2026-10-12 Hyprland dark:** passed; also covered by the installed GTK scenario `selection_statistics_summarise_the_selected_rows`.
- [ ] Run a failing statement in the editor: Copy error places the exact error text on the clipboard. **2026-10-12 Hyprland dark:** passed.

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

- [ ] On SQL Server, run `EXEC sys.sp_executesql N'SELECT 1 AS first_result; SELECT 2 AS second_result;'` as one query. Confirm the result-set selector shows both sets in source order and each displays its own column and value.
- [ ] Run `SELECT 1 AS one; SELECT 2 AS two;`, pin both results, then run `SELECT 3 AS three;` and `SELECT 4 AS four; SELECT * FROM missing_table;`: pinned results stay first and the failed second statement is labelled **Statement 2**, not Statement 4. Unpin removes the pinned results. **2026-10-12 historical run:** pin ordering passed, but failure numbering after pinning was not checked; fixed by [#785](https://github.com/cozyGarage/BookiE/pull/785). The installed GTK scenario `pinned_results_stay_ahead_of_the_next_run` covers the failure; installed Wayland retest pending ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
- [ ] After running a script, each statement's first line shows a tick or, for a failed statement, a cross in the gutter, in light and dark. Edit the script and run it again: the marks follow the new run. **2026-10-12 Hyprland dark:** dark theme passed.

## Carried over from the earlier sprint

- [ ] `cell_editor.rs`: in-place cell editing in light and dark. Held since the `OnceCell` removal.

## Known gaps that are not GTK

- Creating a table from a CSV file falls back to PostgreSQL-leaning type names on ClickHouse, MongoDB, Redis and DuckDB. Only PostgreSQL, MySQL, SQLite and SQL Server have real type-name tables, and none of the four fallback engines was exercised.
- Bundle export and import are covered at the byte level in unit tests and by the keyring tier, but no end-to-end round trip between two real profiles has been run.
- Bundle export and import write administrative audit events. Run a bundle round trip and confirm both events appear in `audit.jsonl` (B4-22).
- SQL-format export and copied INSERT statements now preserve binary values on PostgreSQL, MySQL, SQLite, SQL Server and ClickHouse, with real-engine tests for NULL, empty blobs and all 256 byte values. DuckDB binary SQL literals also have a NULL/empty/all-byte round-trip regression in the B3 ledger; installed acceptance is still pending. Other lossless-contract requirements remain under B3.
