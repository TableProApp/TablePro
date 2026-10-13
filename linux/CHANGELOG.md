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
- `real` values showed extra digits in the grid, copies and exports, such as 0.10000000149011612 for 0.1.
- Exported arrays wrote each row of a multi-dimensional array as a quoted string.

### Security

- CSV export did not neutralise formulas in values of a type TablePro does not recognise.
