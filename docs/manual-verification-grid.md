# Manual verification: grid, filters and data transfer

Part of the [manual verification checklist](manual-verification-0.2-features.md), which holds the setup, evidence and recording rules that apply to every item here.

## Export dialog

Open a result, then Export Results.

- [ ] The Format list offers CSV, JSON, Markdown, HTML, XML, SQL and Excel. **2026-10-12 Hyprland dark:** passed. **2026-10-22 native Wayland, editor query result:** CSV, JSON, Markdown, HTML, XML and SQL were present; Excel was absent. This export was "All rows from a fresh guarded run of this query" with no known total. The current export implementation filters Excel for an unknown total, so this observation does not establish a defect or verify Excel availability for a browse table with a known total.
- [ ] SQL is absent for a MongoDB or Redis connection, present for the others.
- [ ] The CSV options group shows for CSV and hides for every other format. **2026-10-12 Hyprland dark:** passed for CSV and SQL only.
- [ ] A SQL options group with an editable Table name shows only for SQL. **2026-10-12 Hyprland dark:** passed.
- [ ] For a browse tab the Table name is prefilled `schema.table`; for an editor tab it is the tab label, and editing it changes the emitted statements. **2026-10-12 Hyprland dark:** browse tab passed (prefilled `public.customers`, edited name reached the INSERT statements); editor tab not run. Export after a column rename used the old name; fixed by [#676](https://github.com/cozyGarage/BookiE/pull/676); no installed retest is recorded here.
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
- [ ] Progress advances and Cancel stops it. **2026-10-12 Hyprland dark:** failed. The rows were written but the progress dialog stayed at 2 of 2 and Cancel did not close it, [#655](https://github.com/cozyGarage/BookiE/issues/655). **Regression fix:** the GTK widget test verifies the terminal close path works while user closing is disabled; repeat the full import and cancel check on Hyprland.
- [ ] A file with a bad row partway through stops the import and the message says how many rows were written.
- [ ] Import refuses to start on a read-only connection.

## Structure tab, column comments

- [ ] Open an existing Structure tab and make an unsaved change: its title keeps the `· Structure` suffix alongside the dirty marker. The regression test in [#796](https://github.com/cozyGarage/BookiE/pull/796) covers title state; no installed Wayland retest is recorded here.
- [ ] SQLite: create a new table with a foreign key in the Structure tab and save; the table is created with the key. On an existing SQLite table, Add Foreign Key… is greyed out and says SQLite cannot add one to an existing table.
- [ ] A Comment row appears per column on PostgreSQL, MySQL, SQL Server and ClickHouse. **2026-10-12 Hyprland dark:** PostgreSQL passed; others not run.
- [ ] On ClickHouse the field is populated but not editable for an existing column, with a tooltip saying why.
- [ ] No Comment row appears on SQLite or DuckDB.
- [ ] Adding, editing and clearing a comment all save and survive a reload. **2026-10-12 Hyprland dark:** editing and clearing passed on PostgreSQL (checked in the database); adding not run.
- [ ] Renaming a column and editing its comment in the same save works. **2026-10-12 Hyprland dark:** passed on PostgreSQL.

## Active table cell close and preview paths

- [ ] Type into a table cell without pressing Enter, then close it with the tab button and Ctrl+W. Cancel keeps the editor and draft, Save stores the typed value, and Discard leaves the database unchanged.
- [ ] Repeat the pending cell edit through Close Other Tabs, Close Tabs to the Right, window close, quit and Disconnect. Each prompt or teardown decision must wait until the edit is staged; cancel preserves the connection and draft. GTK automation covers the tab button, Ctrl+W, save/discard, inactive-tab close, preview replacement, quit and Disconnect. Verify both tab context-menu actions by hand; see the [active-edit close run evidence](evidence/active-edit-close-cbccd589-2026-10-16/README.md).
- [ ] Type into a preview table cell and open another table. The edited preview becomes a kept tab and retains the pending value. Repeat with a kept tab and with the edited tab inactive.
- [ ] Turn off **Reuse one tab when opening tables** in Preferences, then click three tables in the sidebar. Each opens its own kept tab with no preview icon, and clicking an already-open table selects its tab. Turn the setting back on: the next click opens a preview tab again, and restarting keeps the choice.
- [ ] Attempt closure while a cell editor has an active IME preedit or value popover. Closure is refused without discarding or replacing the in-progress input.
- [ ] Close a tab while its save is in flight, then deliver a late save completion after opening a replacement tab. The completion must not close or change the replacement.

## ENUM and SET pickers (PostgreSQL, MySQL and MariaDB)

- [ ] Double-click an ENUM cell: a list of the declared members opens with the current one highlighted; choosing another shows a pending change and Save writes that member. **2026-10-12 Hyprland dark:** passed on PostgreSQL; the keyboard highlight starts on the first member, [#660](https://github.com/cozyGarage/BookiE/issues/660). **2026-10-22 installed binary in Xvfb/AT-SPI, MySQL 8.0:** selected `done` from `ready`, observed a pending edit, saved it, and verified the server value; the rest of the fixture, including SQL NULL and empty values, remained unchanged. Initial highlight behavior was not asserted.
- [ ] Choose the (empty) member of an ENUM that declares one: the cell shows empty and the stored value is the empty string, not NULL.
- [ ] Double-click a SET cell: each member has a check; toggling and pressing Apply writes the members in declared order; with none checked the stored value is the empty set, not NULL. **2026-10-12 Hyprland dark:** declared order passed on MariaDB (`red,green,blue`); the empty set not run. That run found the popover clipped its labels; the current popover behavior has not been retested. This was also reported in [#657](https://github.com/cozyGarage/BookiE/issues/657), which is closed after the editor-toolbar fix. **2026-10-22 installed binary in Xvfb/AT-SPI, MySQL 8.0:** changed `read` to `read,write`, applied and verified declared order; existing SQL NULL and empty-set rows remained intact. Clearing all members to actively write the empty set was not tested.
- [ ] Set to NULL from the cell menu still works on a nullable ENUM or SET.
- [ ] On PostgreSQL, an enum column offers its labels in declared order; a column of an enum array type still opens the text editor.

## Paste into cells

- [ ] Copy a 2 by 2 block from a spreadsheet, click a cell in a browsed table with at least two rows and columns below and right of it, press Ctrl+V: four cells show as pending changes and the unsaved-change count reads 4. **2026-10-12 Hyprland dark:** passed.
- [ ] Paste a block that runs past the last loaded row or column: a toast says so and nothing changes. **2026-10-12 Hyprland dark:** passed for the last column; the last row is covered by the installed GTK scenario `paste_past_the_loaded_rows_changes_nothing`.
- [ ] Paste a value that does not parse for its column type: a toast names the column and row and nothing changes. **2026-10-12 Hyprland dark:** passed.
- [ ] Paste with no cell focused: a toast asks you to click a cell first.

## Go to Referenced Row

- [ ] In a table with a foreign key, right-click a non-empty value in the key column: Go to Referenced Row opens the referenced table with one filter rule on the referenced column. **2026-10-12 Hyprland dark:** failed because foreign keys arrived after the grid was drawn; fixed by [#664](https://github.com/cozyGarage/BookiE/pull/664); no installed retest is recorded here.
- [ ] On a cell of a column that is not a foreign key, or on a NULL key, the item is greyed out.
- [ ] With the referenced table already open, the same action switches to that tab and replaces its filter.
- [ ] A composite key filters every referenced column from the same row; with one of its columns hidden, a toast says so.

## Filter by This Value

- [ ] Right-click a cell in a browsed table: Filter by This Value narrows the rows and the filter strip shows the new rule. **2026-10-12 historical run:** filtering passed, but the rule editor opened collapsed; fixed by [#820](https://github.com/cozyGarage/BookiE/pull/820). The installed GTK scenario `filter_by_this_value_narrows_the_browse_rows` covers the filter action; no installed retest of the expanded editor is recorded here ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
- [ ] On a NULL cell it filters with IS NULL.
- [ ] Doing it again on another value of the same column replaces that rule.
- [ ] A JSON or binary cell shows "Values of this type can't be used as a filter". **2026-10-12 Hyprland dark:** JSON passed; binary not run.
- [ ] The item is absent from SQL editor result grids.

## Named browse filters

- [ ] On one table, build and apply two structured filters, save them under different names, and switch between them without editing the rules. **2026-10-12 Hyprland dark:** passed.
- [ ] Rename one preset and delete the other; restart BookiE and confirm the renamed preset remains scoped to the same connection, schema and table. **2026-10-12 Hyprland dark:** passed.
- [ ] Save a preset with raw SQL, an empty name, an overlong name and beyond the per-table limit; each is refused with a useful message. **2026-10-12 Hyprland dark:** raw SQL and empty name refused; the name field stops at 48 characters; the per-table limit not run.
- [ ] Open the preset on a table whose columns changed; the invalid saved rule is not applied silently.

## MongoDB sorted browse

Use a stable collection with enough documents to browse multiple pages. These checks confirm installed behavior; pages outside the ascending `_id` keyset path use offset pagination, so record the collection size and query conditions when noting performance.

- [ ] Sort by a supported field in ascending and descending order; each page follows the selected order.
- [ ] Apply a filter and sort, then move across several pages; each page keeps the requested order and contains the expected rows.
- [ ] Repeat with a sort other than ascending `_id` and a deep offset; correct ordering is required, but keyset performance is not implied. Installed Arch/Hyprland and representative-network acceptance remain tracked under [#555](https://github.com/cozyGarage/BookiE/issues/555).

## Grid previews for long values

In browse and SQL result grids, text, JSON and binary cells over 8 KiB show a typed preview with the original byte count. SQL result grids are read-only. In an editable browse table, confirm that a long text cell opens for inline editing with the full value, not the preview. **View Value** shows a bounded rendering. **Copy Value** copies complete text and JSON values; binary values currently copy only a byte-count placeholder ([#1587](https://github.com/cozyGarage/BookiE/issues/1587)). Text and JSON cells over 8 KiB and up to 1 MiB can be edited in the bounded full-value dialog. Use text and JSON values just below and just above the 8 KiB threshold, plus a value over 1 MiB for the read-only view.

- [ ] A value below the threshold displays in full and remains editable where that type supports grid edits.
- [ ] Values over the threshold show a prefix and `… (N bytes total)`; SQL result cells and binary/unsupported browse values do not offer inline editing. Editable browse text opens with the full value.
- [ ] View Value shows up to 1 MiB of rendered text or JSON and indicates when longer content is truncated.
- [ ] A long unbroken value wraps without display-only hyphens; the GTK widget regression covers this rendering property ([#791](https://github.com/cozyGarage/BookiE/pull/791)); no installed retest is recorded here.
- [ ] Copy Value copies the complete text or JSON rather than the displayed preview.
- [ ] Repeat with a binary value over the threshold; the preview reports the original byte count and View Value shows at most the first 16 KiB of source bytes as hex with the total byte count.

Binary Copy Value currently copies only the byte-count placeholder; full binary copying is tracked in [#1587](https://github.com/cozyGarage/BookiE/issues/1587).

## Grid cell editing: long text and JSON

Use a keyed table with a nullable text column and values above 8 KiB. Include CRLF, Unicode, trailing spaces and a value near 1 MiB.

- [ ] The cell shows a shortened preview and byte count. Right-click it and choose **Edit Full Value…**; the dialog contains the complete value.
- [ ] Cancel stages no change. Reopen the dialog, change the final character and choose **Apply**; save and reload to confirm the exact text.
- [ ] Apply empty text and confirm it remains empty. Use **Set to NULL** separately and confirm the stored value is SQL NULL.
- [ ] Edit a draft text row, save it, and discard a separate pending edit.
- [ ] A value over 1 MiB is refused. Non-text, generated, key and read-only cells do not offer the action.
- [ ] Edit JSON and JSONB values with reordered keys, duplicate source-text keys, large integer lexemes, JSON `null`, and SQL NULL. Apply valid input and reload to confirm the correct stored carrier; invalid input leaves the dialog open and stages no change.
- [ ] **Format JSON** visibly formats semantic JSON values. Source-text JSON has no lossy formatter; its exact text stays intact until edited. Confirm empty text, JSON `null`, text `null`, and SQL NULL remain distinct.

## Server activity view: binary values

- [ ] Open a connection's activity/session view while a query on a `bytea` or `varbinary` column is visible. A binary value shows as `<N bytes>`, not as a value that reads like a hexadecimal escape (for example not `\x10 bytes`).

## Result headers, selection statistics, error copy and connection strip

- [ ] Browse a table: each column header shows its name, a key marker for primary and foreign keys, and the exact engine type spelling beneath it, in light and dark. **2026-10-12 Hyprland dark:** name and type passed; key markers were missing before [#664](https://github.com/cozyGarage/BookiE/pull/664); no installed retest is recorded here.
- [ ] Select several rows of a numeric column: the selection badge popover lists the column's count, sum, average, min and max, and Copy summary copies them. A text column is not listed. **2026-10-12 Hyprland dark:** passed; also covered by the installed GTK scenario `selection_statistics_summarise_the_selected_rows`.
- [ ] Run a failing statement in the editor: Copy error places the exact error text on the clipboard. **2026-10-12 Hyprland dark:** passed.
