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
| CockroachDB, Redshift, PGlite | Built | Through the PostgreSQL driver |
| TiDB, OceanBase, Databend | Built | Through the MySQL driver |
| Redis | Partial | StackExchange.Redis. Keys by type, MULTI/EXEC saves, INFO and CLIENT LIST. No Cluster or Sentinel; filters and sorts apply to the loaded page |
| MongoDB | Built | Official driver. A mongosh parser for the editor, inferred columns, saves in a transaction on replica sets; the review shows mongosh commands |
| ClickHouse | Built | ClickHouse.Client over HTTP. Saves are synchronous mutations probed to touch one row; no ON CLUSTER |
| Oracle | Built | ODP.NET managed. PL/SQL blocks end at a lone /. DBMS_OUTPUT and SQL*Plus commands are not handled |
| Teradata | Partial | Teradata .NET provider. No activity view; paging orders by a constant until the browse passes its sort to paging |
| Cassandra, ScyllaDB | Built | DataStax driver. Values go through romJson, saves are one logged batch, paging by paging state; Amazon Keyspaces SigV4 |
| DynamoDB | Built | AWS SDK. Scan paging, filter expressions, conditional TransactWriteItems saves, PartiQL editor; no GSI query path |
| Snowflake | Partial | Snowflake.Data. Key-pair and browser sign-in; structure is read-only |
| BigQuery | Built | Google client. Dry-run byte limit, saves as one script in a transaction; nested fields are read-only |
| Spanner | Built | Google client. DDL through the admin API, saves retried on abort; GoogleSQL databases only |
| Trino | Partial | REST protocol. Values are typed literals since the protocol cannot bind; saves are probed but not atomic |
| Elasticsearch | Built | REST. Deep paging with a point in time, bulk saves, tasks with cancel |
| Typesense, Weaviate | Built | REST and GraphQL. Weaviate writes one request at a time |
| SurrealDB | Partial | HTTP /sql. Saves in one transaction; datetimes and decimals arrive as text |
| Kafka | Partial | Confluent.Kafka. Topics browse merged by timestamp, KafkaQL editor, consumer groups with lag; inserts only. librdkafka has no win-arm64 build, so Kafka does not load on Arm64 |
| etcd | Built | v3 JSON gateway. Prefix browsing, etcdctl editor, saves as compare-and-swap transactions |
| Cloudflare D1, R2 SQL | Built | REST. D1 saves are one checked batch; R2 SQL is read-only and stops at 10,000 rows |
| libSQL, Turso | Partial | Hrana over HTTP with a stream per tab. No local file mode or structure editor |
| Dameng, SAP HANA | Partial | Through the vendor's 64-bit ODBC driver, installed with its client. Catalog, DDL, saves in a transaction, activity with kill; written from vendor documentation and not yet run against a server |
| Beancount | Built | Read-only. The ledger and its includes are projected into SQLite by beancount or rledger, rebuilt when a file changes; BQL needs rledger |
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
| Import and export connections | Built | macOS format 1 and 2, with the macOS passphrase encryption carrying saved passwords; imported tunnel commands start turned off |
| Database switcher, schema switcher | Built | |
| SOCKS and HTTP proxy, Cloud SQL proxy, Cloudflare tunnel, tunnel command | Built | Managed loopback forwarders and child processes; commands run without a shell. Not run against live services yet |
| Kerberos, Microsoft Entra ID, IAM sign-in | Partial | Entra ID for SQL Server and Azure PostgreSQL/MySQL, AWS RDS IAM, Kerberos with the Windows logon ticket. No Google Cloud IAM or Redshift IAM |
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
| Open Quickly: fuzzy switcher across objects, databases, schemas and open tabs | Built | Ctrl+Shift+O. Ranked by match, kind and how often and lately each was opened, saved per connection |
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
| Multiple cursors | Built | Ctrl+D next occurrence, Ctrl+Shift+L all, Ctrl+Alt+Up/Down, Alt+click, Alt+Shift+drag column selection; one undo step for all carets |
| Vim mode | Built | Settings > Editor. Modes, counts, operators, motions, text objects, registers, marks, macros, search, dot repeat; `:w` saves, `:q` and `gt` act on tabs. Windows shortcuts (Ctrl+C, V, Z, F) keep their meaning. No visual block mode |
| Emacs keys | Built | Settings > Editor, exclusive with Vim. Kill ring, mark, word motions; those Ctrl keys lose their Windows meaning in the editor |
| Graphical query plan, plan comparison | Built | Diagram, tree with cost bars, raw text and Compare with the previous plan. PostgreSQL, MySQL, SQL Server, SQLite, DuckDB, ClickHouse, Oracle; Explain Analyze where the engine measures. No saved plan history |
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
| Result maps | Built | WKB, WKT, GeoJSON, GeoPackage and lat/long columns drawn on a Web Mercator grid with pan and zoom; no map tiles |
| XLSX export | Built | Streamed workbook with a frozen header and typed cells |
| Parquet export | Built | Streamed row groups, Snappy, Zstd or Gzip, types from the result columns |
| Screen reader support inside the grid | Built | Grid and Table patterns; Narrator reads column, row and value as the cell moves. Table-level column headers come back empty to UI Automation clients |

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
| SQL import, import mapping editor | Partial | Streamed SQL import with a transaction and progress; a mapping editor for CSV and JSON into an existing or new table. Insert only, mappings are not remembered |
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
| Users and roles editing | Partial | PostgreSQL, MySQL and MariaDB, SQL Server: principals, attributes, memberships and grants at every scope, staged with undo and reviewed before apply. Other engines list users only; one principal selected at a time |
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
| MCP pairing, audit log persistence | Built | Pairing over HTTP with PKCE and an in-app approval, per-client tokens in Credential Manager, a hash-chained audit log kept 90 days. No tablepro:// link |

## Platform

| Feature | Status | Notes |
|---|---|---|
| Fluent Design: acrylic, Mica, Mica Alt, light, dark, high contrast | Built | |
| Settings | Built | |
| Crash log on disk | Built | `%LOCALAPPDATA%\TablePro\logs\errors.log` |
| Keyboard shortcut customization | Built | Settings > Keyboard records chords, warns about conflicts and applies at once; grid keys are fixed |
| Translations | Not built | English only |
| Installer, MSIX package, winget, updates | Built | MSIX, a per-user zip installer, a windows-v* release workflow, a winget template and update checks with a beta channel. Signing needs the release certificate secret |
| Arm64 builds | Partial | The project builds for win-arm64; not tested on hardware |

## Before the first release

1. CI that builds the solution and runs every suite on Windows, plus driver suites against PostgreSQL, MySQL and SQL Server containers.
2. An installer or MSIX package with signing, and a `windows-v*` tag that publishes it.
3. A pass with Narrator and keyboard only, including the data grid.
4. Multiple cursors, which macOS users reach for daily.
