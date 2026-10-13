# Changelog

All notable changes to TablePro for Linux will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Password prompt on connect when the keyring holds no password, with a choice to remember it.
- SSH tunnels through the system OpenSSH client, using your SSH agent, host aliases and jump hosts.
- Security group in the connect dialog: encryption mode, CA certificate, client certificate and TLS server name.
- SQLite file chooser in the connect dialog, with New Database to create a file.
- Results list in the SQL editor with one entry per statement, its rows affected or error, and the open transaction.

### Fixed

- Format, a query opened from history and a loaded SQL file could not be undone with Ctrl+Z.
- PostgreSQL statement timeouts showed as a plain server error when the server's messages were not in English.
- SQL Server money and smallmoney in the SQL editor and query results showed as approximate floats.
- Saving a SQL Server row with a char or varchar key locked the whole table until the save ended.
- Stop could not end a SQLite statement waiting for another connection's lock.
- A SQLite save that failed in a way SQLite rolls back itself closed the connection and its temporary tables.
- A SQLite script ending in an unclosed comment showed later results under the first statement's columns.
- SQLite text containing a NUL character exported as SQL that SQLite cannot read.
- ClickHouse query or export with a FORMAT clause filled memory instead of failing.
- ClickHouse editor tab silently lost its temporary tables and settings when the server expired its session.
- ClickHouse DateTime values showed as UTC text when the server profile or session set ISO output.
- ClickHouse save with an unknown outcome could read as applied because of another table's mutation.
- A new row removed with Delete stayed in the grid while the save left it out.
- A save that failed on a new row did not flash that row.
- The window title showed no unsaved-changes bullet for pending structure changes.
