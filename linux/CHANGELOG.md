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
- ClickHouse query or export with a FORMAT clause filled memory instead of failing.
- ClickHouse editor tab silently lost its temporary tables and settings when the server expired its session.
- ClickHouse DateTime values showed as UTC text when the server profile or session set ISO output.
- ClickHouse save with an unknown outcome could read as applied because of another table's mutation.
