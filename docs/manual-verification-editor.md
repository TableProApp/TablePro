# Manual verification: SQL editor and sessions

Part of the [manual verification checklist](manual-verification-0.2-features.md), which holds the setup, evidence and recording rules that apply to every item here.

## Editor and history

- [ ] At 847 px and 802 px window widths, the navigation sidebar collapses and the main menu, editor Split action and window close control remain visible and usable. At an editor-pane width of 900 px or less, Fold block and Unfold all hide from the toolbar; Ctrl+Shift+[ and Ctrl+Shift+] still fold and unfold SQL blocks. The automated Xvfb scenario checks the main menu, Split and close-control bounds, not the folding controls. Ubuntu floor coverage passed in [#824](https://github.com/cozyGarage/BookiE/pull/824); the original report is [#657](https://github.com/cozyGarage/BookiE/issues/657). **2026-10-22 native Wayland:** screenshots at 922 px (sidebar open) and 802 px (sidebar collapsed) show Run and Split visible without literal overlap; controls were not activated. The repeated Xvfb warning about a 964 px editor toolbar minimum in 910 px has no confirmed visual clipping; see [installed evidence](evidence/installed-wayland-0.2.0-2026-10-22/README.md). Native activation and the 900–964 px range remain untested.

- [ ] Toggle **Split** on and off with the mouse and keyboard; edit the query from either pane, confirm both views update, and check that each pane keeps its scroll position at a narrow window width. **2026-10-12 Hyprland dark:** mouse toggle and shared buffer passed; keyboard and narrow width not run. The orphaned-tab abort was fixed by [#667](https://github.com/cozyGarage/BookiE/pull/667); repeat the installed flow.
- [ ] Ctrl+O opens a `.sql` file into a new tab titled with the file name. **2026-10-12 Hyprland dark:** passed.
- [ ] Typing marks the title with `•`; Ctrl+S saves, clears the mark and shows "Saved". **2026-10-12 Hyprland dark:** passed.
- [ ] Ctrl+S on an editor tab never opened from a file asks where to save.
- [ ] Ctrl+Shift+S saves to a new file and the tab then follows that file.
- [ ] Change the file in another editor, then press Ctrl+S: the "changed on disk" dialog appears. Cancel leaves both copies alone; Overwrite writes yours; Save As… writes elsewhere. **2026-10-12 Hyprland dark:** Cancel and Overwrite passed; Save As not run.
- [ ] Closing a tab with unsaved file changes asks Save/Discard/Cancel, and Save closes it only after the file is written. **2026-10-12 Hyprland dark:** the prompt passed; Save wrote the file but the tab stayed open. Fixed by [#667](https://github.com/cozyGarage/BookiE/pull/667); no installed retest is recorded here.
- [ ] Saving a file that is a symlink updates its target and keeps the link.
- [ ] Restart with a file tab open: the tab is titled by the file again, unsaved edits still show `•`, and Ctrl+S saves to the same file.
- [x] Restart with a saved connection, an active editor draft, a kept table tab and a preview table tab: restore the connection, draft and kept tab, omit the preview tab, and do not execute the draft until Run. **2026-10-22 installed 0.2.0 binary, isolated Xvfb/AT-SPI:** passed 1/1; the draft then ran against the restored connection. See [installed Wayland and package evidence](evidence/installed-wayland-0.2.0-2026-10-22/README.md). Native Wayland repeat remains untested.
- [ ] Delete that file, then restart: the tab keeps its text and a toast says it is no longer linked.
- [ ] Ctrl+S on a browse or structure tab still saves pending edits there.
- [ ] A `.sql` file above the size limit is refused with an explanation, not truncated.
- [ ] Ctrl+Shift+D lists saved queries; open, rename and delete all work.
- [ ] Saving a structure change or edited rows appears in history, and the history dialog can filter those out.
- [ ] `TABLEPRO_LOG_FORMAT=json ./target/debug/tablepro` writes lines that parse as JSON; unset keeps the human format.

## Editor sessions (PostgreSQL, MySQL, SQL Server and SQLite files)

- [ ] Turn on Session in an editor tab: `SET search_path` and a `CREATE TEMP TABLE` from one run are still in effect on the next run.
- [ ] `BEGIN`, then an `UPDATE` in a later run: the button reads "Session · transaction open"; another tab cannot see the change. **2026-10-12 Hyprland dark:** passed (label read "Session · transaction open"; a separate psql session did not see the change).
- [ ] In a MySQL Session transaction, locking reads, `SET @user_variable`, savepoints and supported `SHOW` forms run; raw `BEGIN`, `COMMIT` and `ROLLBACK`, DDL, account statements, `LOCK TABLES` and `SET autocommit` remain refused. Confirm `ROLLBACK` leaves user-variable values unchanged and does not release named locks acquired by functions in assignment expressions; release the lock explicitly.
- [ ] Turning Session off with a transaction open asks Commit / Roll Back / Cancel, and each does what it says; Cancel leaves the session on. **2026-10-12 Hyprland dark:** Cancel and Commit passed; Roll Back not run.
- [ ] Turn Session off while idle: after close completes, the transient closing status disappears and Run is enabled.
- [ ] Closing the tab with a transaction open asks first; Roll Back and Close leaves the table unchanged.
- [ ] Without Session, a lone `BEGIN` is refused and the message mentions Session. **2026-10-12 Hyprland dark:** passed.
- [ ] On ClickHouse or an in-memory SQLite database, turning Session on explains that the engine does not offer it yet and the button turns back off.
- [ ] The audit journal shows the session's COMMIT or ROLLBACK against the same batch as the statements inside it. **2026-10-12 Hyprland dark:** COMMIT passed (same `batch_id` as the UPDATE).

## Session failure and shutdown paths (B4 I4)

- [ ] Stop appears only where server cancellation is supported; stopping a session query records the terminal outcome and permits later supported queries.
- [ ] A session timeout reports its actual cancelled/unknown state in the UI and audit; it does not present an ambiguous write as safely undone.
- [ ] Failed COMMIT after an aborted PostgreSQL transaction shows rollback; a deferred-constraint failure clears the transaction-open state and retry does not fabricate a second commit. **2026-10-22 installed binary in Xvfb/AT-SPI:** the aborted transaction rolled back with zero rows; rolling back to a savepoint and committing stored exactly one row. Deferred-constraint behavior was not covered.
- [ ] Window close and Disconnect with an open transaction ask first, honor Cancel, and finish the chosen rollback/commit before teardown; verify persisted rows.
- [ ] With an editor Session open, stop the database host (or block its port) and close the window. After the cleanup timeout, **Could not close database sessions** offers **Keep Open** (default) and **Close Anyway**; Close Anyway closes the window, Keep Open leaves it usable.
- [ ] A retired session turns its toggle off; late state messages cannot relabel a replacement session. Automatic reconnect retires the previous tab sessions.
- [ ] An unknown write outcome blocks only its owning connection; another connection stays usable. Restart/reconnect recovery follows the durable audit rules.
- [ ] `SET autocommit=0`, `SET IMPLICIT_TRANSACTIONS ON`, `XA START` and an unterminated transaction batch are refused on applicable shared connections.

## Explain tree

- [ ] On PostgreSQL, Explain a join: the dialog opens on a Tree tab with nested steps, a cost bar per step and the filter or condition lines under their step; the Text tab shows the raw plan. **2026-10-12 Hyprland dark:** tree, cost bars and condition lines passed; the Text tab not checked. The Tree and Text switcher showed missing icons, [#656](https://github.com/cozyGarage/BookiE/issues/656); icon names now use icons present in Adwaita and Yaru, awaiting a Hyprland retest.
- [ ] Press Escape while the Explain plan dialog is open: the dialog closes. The installed GTK scenario `explain_plan_window_closes_on_escape` covers this behavior ([#781](https://github.com/cozyGarage/BookiE/pull/781)); no installed Wayland retest is recorded here.
- [ ] On SQLite, Explain a query that scans and searches: steps nest by their parent.
- [ ] On MySQL, ClickHouse or DuckDB the dialog shows the text plan with no Tree tab.
- [ ] Explain on an empty editor still shows the existing message.
- [ ] On a connection where a plan takes a few seconds (for example `EXPLAIN ANALYZE SELECT pg_sleep(20)` on PostgreSQL), open the Explain window and close it at once. In the database's activity view the statement is gone within about a second, not after the query timeout.

## SQL code folding

- [x] Place the cursor inside a multiline CASE block and press Ctrl+Shift+[. The block body folds and its opening and closing lines remain visible. **2026-10-22 native Wayland, dark:** passed on the installed 0.2.0 binary; the CASE body hid while `SELECT CASE` and `END AS case_value` remained visible, and the accessible query text was unchanged. Screenshots were captured locally but are not retained in the repository.
- [x] Click the fold marker in the gutter. The body returns without changing the query text. **2026-10-22 native Wayland, dark:** passed on the installed 0.2.0 binary. A down-chevron appeared beside the multiline CASE; clicking it restored the hidden body. The CASE query remained unsaved and was not run. Screenshots were captured locally but are not retained in the repository.
- [x] Fold two blocks, then use Unfold all and Ctrl+Shift+]. Both show the complete query. **2026-10-22 native Wayland, dark:** two CASE blocks folded independently; Unfold all restored both, and Ctrl+Shift+] restored the single-block case. The sentinel statement remained unchanged.
- [x] Edit the query while a block is folded. The editor reveals the full query and clears stale fold markers. **2026-10-22 native Wayland, dark:** typing `s` at the end of the folded `'one'` literal changed it to `'ones'` and revealed the full CASE body. The test query was not run or saved. Screenshots were captured locally but are not retained in the repository.

## Pinned results and gutter marks

- [ ] Run `SELECT 1 AS first;`, then run `SELECT pg_sleep(3), 2 AS second;`: while it runs, the first result stays on screen, dimmed, with Running… and the spinner in the toolbar; when it finishes the dimming is gone and the second result is shown. Repeat with a query that fails, with Cancel, and with a statement that times out: each replaces the dimmed result. A streamed PostgreSQL SELECT keeps the previous result until its first page arrives.

- [x] On SQL Server, run `EXEC sys.sp_executesql N'SELECT 1 AS first_result; SELECT 2 AS second_result;'` as one query. Confirm the result-set selector shows both sets in source order and each displays its own column and value. **2026-10-22 installed 0.2.0 native Wayland:** passed. The selector listed Result set 1 then Result set 2; selecting each displayed its matching column/value (`first_result = 1`, `second_result = 2`). The `EXEC` batch prompted for approval before running; approved once. App status reported 17 ms. See [the installed Wayland evidence](evidence/installed-wayland-0.2.0-2026-10-22/README.md).
- [ ] Run `SELECT 1 AS one; SELECT 2 AS two;`, pin both results, then run `SELECT 3 AS three;` and `SELECT 4 AS four; SELECT * FROM missing_table;`: pinned results stay first and the failed second statement is labelled **Statement 2**, not Statement 4. Unpin removes the pinned results. **2026-10-12 historical run:** pin ordering passed, but failure numbering after pinning was not checked; fixed by [#785](https://github.com/cozyGarage/BookiE/pull/785). The installed GTK scenario `pinned_results_stay_ahead_of_the_next_run` covers the failure; no installed Wayland retest is recorded here ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
- [ ] After running a script, each statement's first line shows a tick or, for a failed statement, a cross in the gutter, in light and dark. Edit the script and run it again: the marks follow the new run. **2026-10-12 Hyprland dark:** dark theme passed.
- [ ] PostgreSQL: pin a result, then run a long streamed SELECT and press Stop (or let it time out): the pinned result stays above the Cancelled or Timed out page, and Pin is unavailable while the stream is still loading.

## Closing a window during a save

- [ ] Start a structure save that fails on the server (for example, add a NOT NULL column without a default to a table that has rows), then close the window while it runs. The "Saving in progress" dialog closes when the save ends, and only the unsaved-changes prompt remains.

## Exact SQL completion

- [ ] On PostgreSQL, create distinct `users` and `"Users"` relations, plus a relation with a space or escaped quote in its name. Use Ctrl+Space to open completion, select each relation with the arrow keys, and accept with Enter or Tab. Run the resulting SELECT and confirm the intended relation. Repeat in the split editor view.
- [ ] Complete an alias-qualified column in the middle of a query. The alias and following SQL stay intact. Undo restores the original identifier in one step.
- [ ] With a screen reader, confirm completion names can be read and selected. This remains a manual accessibility check; provider activation tests do not establish screen reader behavior.

## Editor bottom panel

- [x] On native Arch/Hyprland, run a query with a unique visible value, hide/show Results by button and Ctrl+J from SQL and the result grid, and confirm the same result and selection remain.
- [x] Resize the divider, maximize/restore, and hide while maximized. Confirm the normal divider size and the previously focused SQL split are restored.
- [x] Check 1,200 px with normal SQL text and 802 px with a 20-point SQL font in light/dark themes. Every panel control remains reachable.
- [x] Run successful, failed and timed-out queries. Errors shows only the latest accepted failures; switching views does not hide or rerun the result set.
- [x] Close a query with the panel hidden while another editor remains open. Its controls still work and no late result revives the closed editor.

Source tests and native acceptance for this change are recorded in its PR and linked evidence; the checklist is not automatically satisfied by Xvfb.

The [October 22 source-built desktop matrix](evidence/editor-bottom-panel-2026-10-22/README.md) covers these panel interactions on Arch/Hyprland. Packaged acceptance and broader accessibility qualification remain separate.

## Editor error navigation

- [x] On native Wayland with PostgreSQL, run a script whose third statement fails after a Unicode value. Go to error in the result restores a maximized editor and places the caret at the failed statement's exact character position.
- [x] Run Current with two identical statements through real Ctrl+Shift+Enter. Go to error moves the caret to the second occurrence. SQL inside a leading comment is not used as a navigation target or marked as executed.
- [x] Use Go to error from the Errors view. Edit the query and retry the old action; the caret stays put and a fresh run is requested. A unique database row confirms navigation never reruns the script.
- [x] Reach the action by mouse in a 1,200 px dark window and an 802 px light window with 20-point SQL text. Error controls remain visible above scrollable text.

The [source-built acceptance record](evidence/editor-error-navigation-2026-10-22/README.md) pins the executable and screenshots. New-run and closed/replaced-connection refusal, invalid positions and rewritten parameters have separate source regressions. Release packages, distro-floor runs and Orca remain separate acceptance.
