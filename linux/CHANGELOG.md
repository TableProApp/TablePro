# Changelog

All notable changes to TablePro for Linux will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first release of TablePro for Linux, a GTK 4 and libadwaita app for GNOME 50 and later.
It connects to PostgreSQL, MySQL and MariaDB, SQL Server, ClickHouse and SQLite, directly or through an SSH tunnel.
Ubuntu 26.04 and 26.10 install it from a Launchpad PPA, and Fedora 44 and later from COPR.

### Added

- Saved connections with groups, colours, TLS options and read-only mode, and passwords kept in the system keyring.
- SSH tunnels through the system OpenSSH client, with your agent, `~/.ssh/config`, jump hosts and host key checks.
- SQL Server sign-in with Kerberos, using the ticket from `kinit`.
- A window per connection, with its table, structure and SQL editor tabs reopened at the next launch.
- Table grid with filters, sorting and paging, editing in place, new and deleted rows, and undo until you save.
- Structure tab to change columns, indexes and foreign keys, with the SQL shown before it runs.
- SQL editor with completion, formatting, find and replace, a result per statement, and Stop.
- Query history with full-text search, and saved queries.
- Export to CSV, JSON, SQL, Excel, Markdown, HTML and XML, CSV import, and Copy As.
- Open SQLite files from the file manager's Open With, or with `tablepro file.sqlite3`.
- Keyboard navigation of the grid, and names and states for screen readers.
- Desktop notification when a query, save or export finishes in a tab you are not looking at.
- Troubleshooting in About TablePro, with the versions to paste into a bug report.
