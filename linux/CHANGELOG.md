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

### Changed

- Structure tab offers only the changes the database can make, and says why a control is off.
- Show CREATE TABLE gives the server's own statement on MySQL, ClickHouse and SQLite.

### Fixed

- Format, a query opened from history and a loaded SQL file could not be undone with Ctrl+Z.
- PostgreSQL statement timeouts showed as a plain server error when the server's messages were not in English.
- MySQL and MariaDB connections that verify the certificate did not trust certificate authorities installed on the system.
- SQL Server money and smallmoney in the SQL editor and query results showed as approximate floats.
- Saving a SQL Server row with a char or varchar key locked the whole table until the save ended.
- Stop could not end a SQLite statement waiting for another connection's lock.
- A SQLite save that failed in a way SQLite rolls back itself closed the connection and its temporary tables.
- A SQLite script ending in an unclosed comment showed later results under the first statement's columns.
- SQLite text containing a NUL character exported as SQL that SQLite cannot read.
- ClickHouse query or export with a FORMAT clause filled memory instead of failing.
- ClickHouse editor tab silently lost its temporary tables and settings when the server expired its session.
- Running a ClickHouse statement right after stopping one failed because the server still held the session.
- ClickHouse DateTime values showed as UTC text when the server profile or session set ISO output.
- ClickHouse save with an unknown outcome could read as applied because of another table's mutation.
- A new row removed with Delete stayed in the grid while the save left it out.
- A save that failed on a new row did not flash that row.
- Undo after editing a cell twice restored the fetched value instead of the first edit.
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
- Changing a MySQL column in the Structure tab dropped its collation, ON UPDATE, INVISIBLE and SRID, and a comment turned a generated column into a plain one.
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
- A save whose answer was lost with the connection showed as failed, and saving again could apply it twice.
- Edits made in a table tab while its save ran were dropped when the save finished.
- Ctrl+S did nothing in a Structure tab.

### Security

- CSV export did not neutralise formulas in values of a type TablePro does not recognise.
- Format could put a space inside `+=`, `b'01'` or `@@version`, or between a MySQL function such as `GROUP_CONCAT` and its parenthesis, and change what the statement does.
- Opening a pipe or a device as a SQL file never finished, or read past the 8 MB limit.
- Importing a CSV or a connections file from a pipe or a device never finished, a CSV could read past its size limit, and a connections file had none.
- SQL run in the editor, a typed filter or a column default, and the values in them, reached the journal at debug level.
- Column types and defaults typed in the Structure tab reached the SQL after a text filter instead of the database's own parser.
