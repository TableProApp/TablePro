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
- A refresh that failed replaced the rows in a table tab with an error page.
- Switching connections could show the previous connection's tables in the sidebar, or its reconnect banner.

### Security

- CSV export did not neutralise formulas in values of a type TablePro does not recognise.
- Format could put a space inside `+=`, `b'01'` or `@@version`, or between a MySQL function such as `GROUP_CONCAT` and its parenthesis, and change what the statement does.
- Opening a pipe or a device as a SQL file never finished, or read past the 8 MB limit.
- Importing a CSV or a connections file from a pipe or a device never finished, a CSV could read past its size limit, and a connections file had none.
- SQL run in the editor, a typed filter or a column default, and the values in them, reached the journal at debug level.
