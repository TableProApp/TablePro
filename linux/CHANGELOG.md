# Changelog

All notable changes to TablePro for Linux will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Password prompt on connect when the keyring holds no password or the server refused it, with a choice to remember it.
- SSH tunnels through the system OpenSSH client, with your agent, host aliases and jump hosts, confirming new host keys.
- Security group in the connect dialog: encryption mode, CA certificate, client certificate and TLS server name.
- SQLite file chooser in the connect dialog, with New Database to create a file.
- Results list in the SQL editor with one entry per statement, its rows affected or error, and the open transaction.
- SQL editor completion of tables, views and columns from the database, resolving aliases and matching fuzzily.
- Stop Saving in table and structure tabs, and in the dialog that waits for a save before closing.
- Save Changes dialog on close that lists every tab with unsaved changes and saves only the ones left checked.
- Logout waits while there are unsaved changes, and logout and suspend wait while a save is running.
- Auto-increment on and off for PostgreSQL columns in the Structure tab, numbering on from the largest existing value.
- SQLite column type, nullability, default and primary key changes, and foreign keys added or removed, in the Structure tab.
- Delete button in the table grid, with the reason in its tooltip when the selected rows can't be deleted.
- Set to DEFAULT in a new row's cell menu, for columns the server fills.
- New Window (Ctrl+Shift+N, or `tablepro --new-window`) opens another window in the running TablePro.
- Connections wait offline while the network can't reach their server, and reconnect once it can or after a suspend.
- Review Key in a connection's banner when its SSH host key is refused, to trust a new key, replace a changed one, or retry once the key is fixed outside TablePro.
- Read-only or read-write choice before opening a SQLite file on a network share or FUSE filesystem.
- Locate… for a saved SQLite connection whose file was moved or renamed.
- Open SQLite files from the file manager's Open With, or with `tablepro file.sqlite3`.
- Review before a structure save that drops data, rebuilds the table or can stop halfway, with the SQL it runs.
- Arrow keys move between grid cells; F2 or Return edits one, Tab carries an edit to the next cell, and Shift+F10 opens the cell menu.
- Screen readers name check box cells and say when a grid cell is modified or NULL and a row new or marked for deletion.
- Connections open when TablePro quits open again at the next launch; Restore Session in Preferences turns it off.
- Save Query History in Preferences turns the query history off and keeps the entries already saved.
- Try Again on a table tab's error page, and Retry on a banner over rows or a structure that could not be read again.
- Table and structure tabs show a spinner in the tab bar while they read.
- Count Rows in a table tab's paginator, with the reason on Try Again when a count fails.
- Exports write in the background, with progress and Stop in the header bar, and a close or quit asks to stop them first.
- Export a table's current page or every row under its filter and sort, and an editor result's shown rows or all of them.
- Banner over an editor result the row limit cut short, saying how many rows it shows, with Export All for every row.
- Sort an editor result by clicking a column header, with text in your language's alphabetical order.
- Copy As puts CSV, JSON, Markdown, SQL and tab-separated rows on the clipboard as their own type beside plain text.
- Shift+F10 opens the menu of a sidebar table or a query history entry, as the Menu key does.
- Screen readers name icon-only buttons, and announce the shortcut of the table, SQL editor and filter buttons that have one.
- An icon beside each table row with a pending change, and bold text in edited cells.
- Troubleshooting in About TablePro, with the app, toolkit and driver versions to copy into a bug report.
- Licenses of the third-party crates TablePro is built with, in About TablePro and installed with the app.
- F9 and the sidebar button show and hide the table sidebar.
- Sidebar lists the tables of every schema, a section per schema with the default one first, and a middle click opens one in a new tab.
- Connect leads a saved connection's menu, which a right click, the Menu key or Shift+F10 opens.
- Find and replace in the SQL editor with Ctrl+F and Ctrl+H, matching case, whole words or regular expressions.
- Edit…, Duplicate and Move to Group in a saved connection's menu; an edit keeps the saved passwords unless you type new ones.
- Desktop notification when a query, save or export finishes in a tab you are not looking at; clicking it opens the tab.
- SSH agent sign-in, Kerberos tickets in KCM and SQLite files on removable drives in the Flatpak build.
- Screenshots of the table grid, SQL editor, Structure tab and connect dialog in the software centre listing.

### Changed

- Structure tab offers only the changes the database can make, and says why a control is off.
- New rows in the table grid take a value for a primary key that is not auto-increment.
- Show CREATE TABLE gives the server's own statement on MySQL, ClickHouse and SQLite.
- Structure tab sets a column NOT NULL when it joins the primary key, and gives its nullability back when it leaves.
- Auto Increment in the Structure tab no longer needs the primary key on PostgreSQL and SQL Server.
- SQLite foreign keys show the name their CREATE TABLE gives them.
- Delete, Duplicate and Copy As in a grid cell's menu act on every selected row when the clicked row is selected.
- Grid cells edit in place with the keyboard each type needs; dates open a calendar, and JSON, XML and long text a larger editor.
- Set Value in a grid cell's menu is Set to Empty, Set to NULL and Set to DEFAULT, each shown only where the column takes it.
- Set a grid cell to NULL with Ctrl+Backspace instead of Ctrl+Shift+N.
- Quit asks each window about its unsaved changes in turn, and waits for open connections to close.
- JSON exports and copies put one row per line, and a value TablePro couldn't read stops the export instead of becoming NULL.
- Each window holds one connection: opening one already open brings its window forward, and Disconnect returns to the list.
- Connecting shows in the window with Cancel, and a failed connect says why with Retry and Edit Connection; screen readers hear both.
- Deleting a connection asks once, offers its window when it is open, and can delete its query history too.
- SQLite files shared through the document portal show their own path instead of the portal's.
- Add Index and Add Foreign Key check the form as you type, and pick the referenced table and columns from the database.
- Denser grid rows, with numbers aligned right in even-width digits at the precision their column declares.
- A grid value too long to draw says how many bytes it leaves out, and its tooltip points to Show Row as JSON.
- Refresh keeps a table's rows, selection and focused cell on screen while it reads the table again.
- A structure tab keeps the table's structure on screen while it reads it again, a save included.
- Opening a large table no longer counts its rows: the paginator shows the server's estimate, and Last waits for a count.
- Saving rows updates a table's total without counting the table again.
- Row counts and page sizes group digits the way the system locale does.
- Query History opens with Ctrl+Shift+H.
- Query History finds any part of a query in any case, and loads more entries as you scroll.
- Query History filters by any connection with history, under its current name, and starts on the window's own.
- Deleting from Query History offers Undo instead of asking first.
- Query History's filters sit under the search bar instead of in a popover, and Today replaces the last 24 hours.
- Show in Files, in Preferences and Query History, selects the history database in its folder.
- Previous and next page are Alt+Page Up and Alt+Page Down; Page Up and Page Down move through the rows.
- Ctrl+S, Ctrl+Z, F5 and Ctrl+F act on the tab that has the focus, so a text field keeps its own undo.
- Keyboard Shortcuts lists every shortcut, grouped by where it works.
- About TablePro links to the website, documentation and issue tracker, and shows a release's notes.
- The sidebar and the tabs each have a header bar, and a narrow window folds the sidebar away and swaps the tab bar for a tab button.
- Sidebar menus offer Edit Structure, Import CSV and Drop Table only on tables, and nothing that writes on a read-only connection.
- New Connection and the main menu sit in the connection list's header bar.
- Each connection group is a section of its own in the connection list, after the connections in no group.
- A tab with unsaved changes or an open transaction shows a dot icon instead of a • in its title.
- The window title names the tab in front and its connection, and the header says when the connection is read-only.
- Tab titles name the schema once the database has two schemas of its own.

### Removed

- Connection buttons in a connected window's header bar; New Window opens another connection.
- Ctrl+E for a new SQL editor tab; Ctrl+T opens one.

### Fixed

- Format, a query opened from history and a loaded SQL file could not be undone with Ctrl+Z.
- Format could split `+=`, `b'01'` or `@@version`, or detach a MySQL function from its parenthesis, and change the statement.
- Opening a SQL, CSV or connections file from a pipe or a device never finished, or read past its size limit.
- Exporting results or query history, or opening the connect dialog, froze the window on a slow disk or network folder.
- A failed query history export said nothing.
- Copying many rows, or showing a row with a long value as JSON, froze the window.
- A query saved just before quitting could be lost.
- The sidebar's table search button had no name for screen readers.
- The sidebar was slow to fill and to search on databases with thousands of tables, and said nothing when the list could not be read again.
- A connection added, changed or deleted in one window did not show in the other windows' connection lists.
- A connection name with & or < in it showed wrong in the connection list.
- PostgreSQL statement timeouts showed as a plain server error when the server's messages were not in English.
- A PostgreSQL query run right after a timeout or Stop could fail as canceled by that earlier stop.
- MySQL and MariaDB connections that verify the certificate did not trust certificate authorities installed on the system.
- SQL Server money and smallmoney in the SQL editor and query results showed as approximate floats.
- Saving a SQL Server row with a char or varchar key locked the whole table until the save ended.
- Stop could not end a SQLite statement waiting for another connection's lock.
- Launching TablePro while it was running did nothing instead of showing the open window.
- Deleting a connection left its saved tabs and editor drafts on disk.
- A change to the connection list made just before quitting could be lost.
- A SQLite save that failed in a way SQLite rolls back itself closed the connection and its temporary tables.
- A SQLite script ending in an unclosed comment showed later results under the first statement's columns.
- SQLite text containing a NUL character exported as SQL that SQLite cannot read.
- ClickHouse query or export with a FORMAT clause filled memory instead of failing.
- ClickHouse editor tab silently lost its temporary tables and settings when the server expired its session.
- Running a ClickHouse statement right after stopping one failed because the server still held the session.
- ClickHouse DateTime values showed as UTC text when the server profile or session set ISO output.
- ClickHouse save with an unknown outcome could read as applied because of another table's mutation.
- A new row removed with Delete stayed in the grid while the save left it out.
- Structure tab collapsed open columns on each add or remove, and lost an edit typed right after one.
- Structure tab column summary and the Default field's error did not update as the column was edited.
- SQLite `INTEGER PRIMARY KEY DESC` columns showed as auto-increment in the Structure tab.
- Undoing a delete of many rows took one Ctrl+Z per row and could not bring back more than 50.
- Editing a number in the grid could round it: integers past 2^53 and floats past six decimal places.
- Setting a new row's cell to NULL saved the column's default instead.
- Setting a NOT NULL cell to NULL was accepted and failed at save.
- The Menu key on a read-only grid cell opened a text selection menu instead of the cell's menu.
- Text with a NUL character showed cut short in the grid, copied cut short, and editing it saved the cut value.
- An edit, Set Value or row action in the table grid could land on another row once a row above it came or went.
- Editing, undoing or deleting a row in the table grid dropped it from a selection of several rows.
- Copy As INSERT could copy the wrong row, drop the schema or unsaved edits, or write a value where the server fills one.
- Duplicate left out the row's unsaved edits.
- Cells of a table without a primary key opened for editing, then dropped what was typed.
- A row whose primary key the driver could not read opened for editing, then failed to save.
- A save that failed on a new row did not flash that row.
- Undo after editing a cell twice restored the fetched value instead of the first edit.
- An edit made while a save ran was dropped when it set the cell back to the value it was read with.
- Refresh or a structure change while edits were pending could save an edit into another column or row.
- Editing a long text cell saved only its first 10,000 characters, and a blob in a text column saved its size label.
- A save that deleted a row and added a new one with the same unique value failed.
- The window title showed no unsaved-changes bullet for pending structure changes.
- `real` values showed extra digits in the grid, copies and exports, such as 0.10000000149011612 for 0.1.
- Excel export rounded integers past 2^53 and wrote decimals as text when their column padded the scale.
- Exported arrays wrote each row of a multi-dimensional array as a quoted string.
- Markdown export broke its table when a column name held a pipe.
- Closed tabs, earlier result pages and structure edits kept using memory until TablePro quit.
- A page read before a filter, sort or page change could replace the newer page when it arrived late.
- Closing a table tab left its query running on the server until it finished.
- Refresh did not show a column added to the table since the tab opened.
- A table tab kept the old header of a column renamed in the Structure tab.
- A table or structure tab whose read failed while the connection was lost kept its error page after the reconnect.
- A refresh that failed replaced the rows in a table tab with an error page.
- Switching connections could show the previous connection's tables in the sidebar, or its reconnect banner.
- The sidebar lost the selected table each time the table list was read again.
- A table tab with no columns the account can read showed a page error instead of saying why.
- Switching connections during a table drop could close the new connection's tabs on a table of the same name.
- Renaming a MySQL table in another database moved it to the connection's database, and renaming a ClickHouse table failed.
- Turning a column's primary key on or off in the Structure tab saved nothing.
- Dropping a SQL Server column that has a default failed.
- Creating a SQLite table with a foreign key failed.
- Changing a column in the Structure tab lost its collation, SRID, SPARSE, CHECK, storage, compression or other attributes it had.
- Saving a MySQL column whose default or generated expression held a quoted string failed.
- Save in a Structure tab's close prompt skipped the tab's checks and dropped a default that did not parse.
- The Structure tab refused every save on a SQLite table keyed by INTEGER PRIMARY KEY.
- Saved tabs and editor text were lost on a disconnect or window close right after a change.
- Every connection's saved tabs were lost when their file could not be read.
- Opening a connection emptied the editor tabs saved for other connections.
- Structure tabs did not reopen with their connection.
- Reopening a connection's tabs stopped at 32 tabs and cut table names longer than 256 bytes.
- Editor tabs reopened after a reconnect in the same window stopped saving their text.
- An editor tab whose saved text could not be read opened empty with no notice, and typing in it overwrote that text.
- Typing in a long SQL script copied the whole script on every keystroke.
- Closing the window never asked about open editor transactions, and never closed the editor tabs' connections.
- Disconnecting or switching connections offered no way to save pending changes first.
- Edits made while a switch to another connection was connecting were closed without asking.
- A save whose answer was lost with the connection showed as failed, and saving again could apply it twice.
- Edits made in a table or Structure tab while its save ran were lost when the save finished.
- Ctrl+S did nothing in a Structure tab.
- Structure tab could not save two columns swapping names, or a column taking the name of one being removed.
- Changing the type of a SQL Server column with a default failed.
- A bulk delete confirmed after the table's primary key changed marked rows by their old key.
- Ctrl+Home and Ctrl+End jumped to the first or last tab instead of the start or end of the SQL editor or table.
- Ctrl+N added a row to a read-only table or a table without a primary key.
- Two SQL editor tabs could both be named Query 3 after an earlier editor tab closed.
- After Clear All, the filter strip could show Match any while the next filter combined its rules with all.

### Security

- CSV export did not neutralise formulas in values of a type TablePro does not recognise.
- SQL run in the editor, a typed filter or a column default, and the values in them, reached the journal at debug level.
- Column types and defaults typed in the Structure tab reached the SQL after a text filter instead of the database's own parser.
- Changing a SQL Server column's type or nullability in the Structure tab removed its data mask.
- A jump host whose ssh_config sets StrictHostKeyChecking to accept-new or no was trusted without the host key dialog.
- Editor SQL saved by an earlier build stayed on disk in a tab file nothing reads any more.
- Statements that set a password, an encryption key or a connection secret were saved in the query history.
