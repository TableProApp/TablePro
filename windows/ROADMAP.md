# Roadmap

What the Windows app has, compared with the macOS app feature by feature, and what is left before a first release. **Built** works in the app today. **Partial** works with the limit the note gives. **Not built** is missing.

## Engines

| Engine | Status | Notes |
|---|---|---|
| PostgreSQL | Built | Npgsql. Catalog queries are not yet run against a live server in CI |
| MySQL, MariaDB | Built | MySqlConnector |
| SQL Server | Built | Microsoft.Data.SqlClient; Windows authentication when no user name is given |
| SQLite | Built | Microsoft.Data.Sqlite; structure changes SQLite cannot express run as a table rebuild |
| DuckDB | Built | DuckDB.NET with DuckDB 1.5 |
| ClickHouse, Cassandra and ScyllaDB, Redis, MongoDB, Oracle | Not built | The macOS app ships these as plugins. Each is one driver project here |
| Snowflake, BigQuery, Spanner, Trino, DynamoDB, Elasticsearch, Cloudflare D1, libSQL and the other registry plugins | Not built | |
| Plugin system | Not planned | Drivers are compiled in, as on Linux (`linux/docs/decisions/0001-no-plugin-system.md`) |

## Connections

| Feature | Status | Notes |
|---|---|---|
| Saved connections, groups, colors, search, sort | Built | |
| Safe Mode, all six levels | Built | Silent, Alert, Alert (Full), Safe Mode, Safe Mode (Full), Read-Only |
| SSL modes | Built | Disabled, Preferred, Required, Verify CA, Verify identity |
| SSH tunnel: agent, key, password, jump hosts | Built | System OpenSSH. Password login is not tested against a live server yet |
| Passwords in the system keychain | Built | Windows Credential Manager |
| Startup commands, extra connection options, connect timeout | Built | |
| Open a SQLite or DuckDB file, from the picker or the command line | Built | The file header picks the engine |
| Import and export connections | Partial | Reads and writes the macOS format 1 bundle; format 2 is refused |
| Database switcher, schema switcher | Built | |
| SOCKS proxy, Cloud SQL proxy, Cloudflare tunnel, tunnel command | Not built | |
| Kerberos, Microsoft Entra ID, IAM sign-in | Not built | SQL Server Windows authentication works |
| iCloud sync | Not planned | Apple-only service |

## Sidebar

| Feature | Status | Notes |
|---|---|---|
| Tables, views, materialized views, functions, procedures, sequences | Built | Grouped, with row estimates where cheap |
| Search | Built | Ctrl+P focuses it |
| Open, structure, definition, select top 1000 | Built | |
| Copy name, copy qualified name, generate SELECT, INSERT, UPDATE, DELETE | Built | |
| Rename, truncate, drop, create table | Built | Each shows its DDL for review first |
| Export a table's data | Built | |
| Quick switcher across databases, recent tab switcher | Not built | |
| Database-wide search for a value | Built | Ctrl+Alt+F. Text columns of up to 500 tables, four at a time; a hit opens the table filtered to the value |

## SQL editor

| Feature | Status | Notes |
|---|---|---|
| Syntax highlighting per dialect | Built | The same lexer splits, classifies and highlights |
| Run statement at caret, selection, all, Explain, Stop | Built | Explain shows the server's text plan |
| Completion: keywords, functions, tables, columns after an alias | Built | |
| Favorites by keyword in completion | Built | |
| Find and replace, comment toggle, indent and outdent, duplicate line | Built | |
| Format SQL | Built | |
| Open and save `.sql` files | Built | |
| Line numbers | Built | |
| Multiple cursors | Not built | |
| Vim mode, Emacs keys | Not built | The setting is stored for when it is |
| Graphical query plan, plan comparison | Not built | |
| Parameter prompts for `?`, `$n` and `:name` | Built | Values are remembered per tab; numbers with a leading zero stay text |
| Language server features (go to definition, diagnostics) | Not built | |

## Results and data grid

| Feature | Status | Notes |
|---|---|---|
| Virtualized grid for large results | Built | Rows and columns are virtualized; a row limit with a notice when cut |
| Several result sets per run, messages, errors | Built | |
| Copy as TSV, CSV, JSON, SQL INSERT, Markdown, WHERE clause, IN list | Built | |
| Export to CSV, TSV, JSON, SQL INSERT, Markdown | Built | Streams to the file |
| Value inspector with JSON formatting | Built | |
| Column resize, auto-fit, multi-column server sort | Built | |
| Result charts | Built | Bar, line and area, category and series picked from the result, up to 500 points |
| Result maps | Not built | |
| XLSX export | Built | Streamed workbook with a frozen header and typed cells |
| Parquet export | Not built | |
| Screen reader support inside the grid | Partial | The grid draws on a canvas, so cells are not announced one by one yet |

## Table tab

| Feature | Status | Notes |
|---|---|---|
| Paging with total count | Built | |
| Filter strip: 17 operators, raw WHERE, match all or any, filter by cell value | Built | Values are always bound as parameters |
| Follow a foreign key to the referenced row | Built | |
| Inline edit, add, duplicate, delete rows, undo and redo | Built | |
| Save in one transaction, refused when a change would touch other than one row | Built | Safe Mode shows the statements first |
| CSV import | Built | Header names map to columns |
| JSON, NDJSON and JSON Lines import | Built | Arrays are streamed; keys map to columns |
| SQL import, import mapping editor | Not built | Run a SQL file covers SQL import |
| Structure: columns, indexes, foreign keys, triggers | Built | |
| Structure editing: add, edit, rename, drop columns, add and drop indexes and foreign keys | Built | DDL is reviewed before it runs |
| Check constraints, partitions, table options editors | Not built | |
| Definition view | Built | |
| Data Rewind, Compare and Sync | Not built | Paid features on macOS |

## Workspace

| Feature | Status | Notes |
|---|---|---|
| Window per connection, tabs, side pane | Built | |
| Reopen a connection's tabs | Built | Settings > General |
| Query history with full-text search | Built | |
| Favorites with folders, keywords and per-connection scope | Built | |
| Server dashboard: sessions with terminate, variables, users | Built | PostgreSQL, MySQL, MariaDB, SQL Server; variables also on DuckDB |
| ER diagram | Built | Up to 150 tables, draggable |
| Export a whole schema to a SQL file | Built | Structure and data |
| Run a SQL file | Built | |
| Users and roles editing | Not built | Listing only |
| Routine debugger | Not built | |
| Join builder, row generator, object copy between connections | Not built | |
| Git and version history for SQL files, linked folders, team library | Not built | |

## AI and MCP

| Feature | Status | Notes |
|---|---|---|
| Assistant chat with schema context | Built | Anthropic, OpenAI, Ollama, OpenAI-compatible servers, Gemini |
| Explain, Optimize, Review, Fix with AI | Built | |
| Per-connection AI policy: ask, allow, never | Built | |
| Suggest while typing | Built | Asks after a pause at the end of a line; Tab accepts |
| MCP server with the nine tools, access levels and write approval | Built | 127.0.0.1 only, bearer token |
| MCP pairing, audit log persistence | Not built | The audit log is in memory |

## Platform

| Feature | Status | Notes |
|---|---|---|
| Fluent Design: acrylic, Mica, Mica Alt, light, dark, high contrast | Built | |
| Settings | Built | |
| Crash log on disk | Built | `%LOCALAPPDATA%\TablePro\logs\errors.log` |
| Keyboard shortcut customization | Not built | |
| Translations | Not built | English only |
| Installer, MSIX package, winget, updates | Not built | The build runs unpackaged and self-contained |
| Arm64 builds | Partial | The project builds for win-arm64; not tested on hardware |

## Before the first release

1. CI that builds the solution and runs every suite on Windows, plus driver suites against PostgreSQL, MySQL and SQL Server containers.
2. An installer or MSIX package with signing, and a `windows-v*` tag that publishes it.
3. A pass with Narrator and keyboard only, including the data grid.
4. Multiple cursors and Vim mode, which macOS users reach for daily.
