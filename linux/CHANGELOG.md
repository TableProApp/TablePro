# Changelog

All notable changes to TablePro for Linux will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Password prompt on connect when the keyring holds no password, with a choice to remember it.
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

### Changed

- Structure tab offers only the changes the database can make, and says why a control is off.
- New rows in the table grid take a value for a primary key that is not auto-increment.
- Show CREATE TABLE gives the server's own statement on MySQL, ClickHouse and SQLite.
- Structure tab sets a column NOT NULL when it joins the primary key, and gives its nullability back when it leaves.
- Auto increment in the Structure tab no longer needs the primary key on PostgreSQL and SQL Server.
- SQLite foreign keys show the name their CREATE TABLE gives them.
- Delete, Duplicate and Copy as in a grid cell's menu act on every selected row when the clicked row is selected.
- Grid cells edit in place with the keyboard each type needs; dates open a calendar, and JSON, XML and long text a larger editor.
- Set Value in a grid cell's menu is Set to Empty, Set to NULL and Set to DEFAULT, each shown only where the column takes it.
- Set a grid cell to NULL with Ctrl+Backspace instead of Ctrl+Shift+N.
- Quit asks each window about its unsaved changes in turn, and waits for open connections to close.

### Fixed

- Format, a query opened from history and a loaded SQL file could not be undone with Ctrl+Z.
- Format could split `+=`, `b'01'` or `@@version`, or detach a MySQL function from its parenthesis, and change the statement.
- Opening a SQL, CSV or connections file from a pipe or a device never finished, or read past its size limit.
- PostgreSQL statement timeouts showed as a plain server error when the server's messages were not in English.
- MySQL and MariaDB connections that verify the certificate did not trust certificate authorities installed on the system.
- SQL Server money and smallmoney in the SQL editor and query results showed as approximate floats.
- Saving a SQL Server row with a char or varchar key locked the whole table until the save ended.
- Stop could not end a SQLite statement waiting for another connection's lock.
- Launching TablePro while it was running did nothing instead of showing the open window.
- A SQLite save that failed in a way SQLite rolls back itself closed the connection and its temporary tables.
- A SQLite script ending in an unclosed comment showed later results under the first statement's columns.
- SQLite text containing a NUL character exported as SQL that SQLite cannot read.
- ClickHouse query or export with a FORMAT clause filled memory instead of failing.
- ClickHouse editor tab silently lost its temporary tables and settings when the server expired its session.
- Running a ClickHouse statement right after stopping one failed because the server still held the session.
- ClickHouse DateTime values showed as UTC text when the server profile or session set ISO output.
- ClickHouse save with an unknown outcome could read as applied because of another table's mutation.
- A new row removed with Delete stayed in the grid while the save left it out.
- SQLite `INTEGER PRIMARY KEY DESC` columns showed as auto-increment in the Structure tab.
- Undoing a delete of many rows took one Ctrl+Z per row and could not bring back more than 50.
- Editing a number in the grid could round it: integers past 2^53 and floats past six decimal places.
- Setting a new row's cell to NULL saved the column's default instead.
- Setting a NOT NULL cell to NULL was accepted and failed at save.
- The Menu key on a read-only grid cell opened a text selection menu instead of the cell's menu.
- Text with a NUL character showed cut short in the grid, and editing it saved the cut value.
- An edit, Set Value or row action in the table grid could land on another row once a row above it came or went.
- Editing, undoing or deleting a row in the table grid dropped it from a selection of several rows.
- Copy as INSERT could copy the wrong row, drop the schema or unsaved edits, or write a value where the server fills one.
- Duplicate left out the row's unsaved edits.
- Cells of a table without a primary key opened for editing, then dropped what was typed.
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

### Security

- CSV export did not neutralise formulas in values of a type TablePro does not recognise.
- SQL run in the editor, a typed filter or a column default, and the values in them, reached the journal at debug level.
- Column types and defaults typed in the Structure tab reached the SQL after a text filter instead of the database's own parser.
- Changing a SQL Server column's type or nullability in the Structure tab removed its data mask.
- A jump host whose ssh_config sets StrictHostKeyChecking to accept-new or no was trusted without the host key dialog.
- Editor SQL saved by an earlier build stayed on disk in a tab file nothing reads any more.
