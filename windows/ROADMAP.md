# Roadmap

What the Windows app has, compared with the macOS app feature by feature, and what is left before a first release. **Built** works in the app today. **Partial** works with the limit the note gives. **Not built** is missing.

## Engines

| Engine | Status | Notes |
|---|---|---|
| PostgreSQL | Built | Npgsql. Catalog queries are not yet run against a live server in CI |
| MySQL, MariaDB | Built | MySqlConnector |
| SQL Server | Built | Microsoft.Data.SqlClient; Windows authentication when no user name is given |
| SQLite | Built | Microsoft.Data.Sqlite; structure changes SQLite cannot express run as a table rebuild. Loadable extensions as on macOS: an ordered list of DLLs with optional entry points in the connection form, loaded into each handle through the C API with the `load_extension()` SQL function kept refused, and a list that arrived from an import or the team library asked about once per connection on this PC before anything loads |
| DuckDB | Built | DuckDB.NET with DuckDB 1.5 |
| CockroachDB, Redshift, PGlite | Built | Through the PostgreSQL driver |
| TiDB, OceanBase, Databend | Built | Through the MySQL driver |
| Redis | Built | StackExchange.Redis. Standalone, Sentinel (primary group, own Sentinel login, failover followed) and Cluster (seed list; DBSIZE, KEYS, SCAN and FLUSHDB across primaries; multi-key commands split by hash slot; single-slot transactions), picked in the connection form's mode controls, which write the macOS `redisMode`, `redisSentinelHosts`, `redisSentinelMasterName`, `redisSentinelUsername` and `redisClusterHosts` options; the Sentinel password is kept in Credential Manager. TLS with a private CA and a client certificate. ElastiCache IAM sign-in (access key, profile or SSO) with a token minted ahead of each reconnect, TLS forced. A database opens as the macOS table of its keys (Key, Type, TTL, Length, Value preview), paged with SCAN that resumes where the last page stopped, a key pattern and a key type sent to the server (SCAN MATCH and TYPE, typed after the scan on servers before 6.0), counted with DBSIZE or a full scan, with TTL edits (EXPIRE, PERSIST), string value edits, renames, new keys and deletes reviewed as redis-cli commands and saved in MULTI/EXEC, one per hash slot on a cluster; Truncate is FLUSHDB. The sidebar groups keys into a namespace tree at the profile's key separator (`redisSeparator`, `:` by default), and a namespace opens the key table narrowed to it. Each key also opens on its own, edited by type. Delete (`DEL`) and Rename (`RENAME`) on keys from the context menu and keyboard, INFO and CLIENT LIST. A cluster serves db0 only. Filters other than key and type, and sorts, apply to the loaded page; SCAN returns keys in hash order, so pages are ordered by key within each page |
| MongoDB | Built | Official driver. A mongosh parser for the editor, inferred columns, saves in a transaction on replica sets; the review shows mongosh commands |
| ClickHouse | Built | ClickHouse.Client over HTTP. Saves are synchronous mutations probed to touch one row; no ON CLUSTER |
| Oracle | Built | ODP.NET managed. PL/SQL blocks end at a lone /. DBMS_OUTPUT and SQL*Plus commands are not handled |
| Teradata | Built | Teradata .NET provider. The first page reads TOP n; later pages number rows with QUALIFY ROW_NUMBER over the browse sort, or the key (else the first column) when unsorted, as macOS does. No activity view, which macOS lacks too |
| Cassandra, ScyllaDB | Built | DataStax driver. Values go through romJson, saves are one logged batch, paging by paging state; Amazon Keyspaces SigV4 |
| DynamoDB | Built | AWS SDK. Scan paging, filter expressions, conditional TransactWriteItems saves, PartiQL editor; no GSI query path |
| Snowflake | Built | Snowflake.Data. Key-pair and browser sign-in. Structure editing within Snowflake's ALTER rules as macOS has them: a VARCHAR only widens, a NUMBER keeps its scale, a default can only be dropped; no indexes, and foreign keys only in CREATE TABLE |
| BigQuery | Built | Google client. Dry-run byte limit, saves as one script in a transaction; nested fields are read-only |
| Spanner | Built | Google client. DDL through the admin API, saves retried on abort; GoogleSQL databases only |
| Trino | Built | REST protocol. Values are typed literals since the protocol cannot bind. Saves count each keyed row first but are not atomic: most connectors refuse writes inside a transaction, and macOS runs them one at a time the same way |
| Elasticsearch | Built | REST. Deep paging with a point in time, bulk saves, tasks with cancel |
| Typesense, Weaviate | Built | REST and GraphQL. Weaviate writes one request at a time |
| SurrealDB | Built | SurrealDB 2 over the RPC in CBOR, as macOS, so datetimes, decimals and record ids arrive typed; SurrealDB 1, which macOS does not support, over HTTP /sql, where declared datetime and decimal fields are read typed. Saves in one transaction |
| Kafka | Partial | Confluent.Kafka. Topics browse merged by timestamp, KafkaQL editor (CREATE and DROP TOPIC, PRODUCE), grid inserts, consumer groups with lag and deleting empty groups, Delete on a sidebar topic, or Drop from its context menu, deletes it. Messages cannot be edited or deleted, and there is no schema registry or topic config editing; macOS has none of these either and does fewer writes. macOS can dial only the bootstrap address through a tunnel, which librdkafka cannot. librdkafka has no win-arm64 build, so Kafka does not load on Arm64 |
| etcd | Built | v3 JSON gateway. Prefix browsing, etcdctl editor, saves as compare-and-swap transactions |
| Cloudflare D1, R2 SQL | Built | REST. D1 saves are one checked batch; R2 SQL is read-only and stops at 10,000 rows |
| libSQL, Turso | Built | Hrana over HTTP with a stream per tab, and local files (a `file:` URL, or macOS's `libsqlMode=local`) through the SQLite driver with its full structure editor. Remote structure edits are the one-statement ones; a type, nullability, default, foreign key or check change needs a table rebuild, which macOS also runs only on a local file. Local files load SQLite extensions as the SQLite connection does; a remote server loads none, as on macOS |
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
| Kerberos, Microsoft Entra ID, IAM sign-in | Built | Entra ID for SQL Server and Azure PostgreSQL/MySQL, AWS RDS IAM, Kerberos with the Windows logon ticket. Google Cloud IAM for Cloud SQL PostgreSQL and MySQL, from application default credentials or a service account key (a file path or the JSON). Redshift IAM from an access key, profile or SSO: `GetClusterCredentials` for a named user, `GetClusterCredentialsWithIAM` without one, and Serverless `GetCredentials`, with an endpoint field for port forwards. A gcloud user login keeps the scopes it was granted, where macOS narrows it to Cloud SQL sign-in |
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
| Language server features (go to definition, diagnostics) | Built | Squiggles for brackets, comments, strings, confusable characters and unknown tables, columns and aliases; hover cards; F12 or Ctrl+click; F2 renames every reference; F8 steps through problems. No signature help |

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
| SQL import, import mapping editor | Built | Streamed SQL import with a transaction, progress and an encoding picker. As on macOS it opens on the last encoding a successful import used, and when that cannot read the first 5 MB it switches to the dump's declared encoding (`SET NAMES`, `client_encoding`, checked first here) or one guessed from the bytes (the macOS detector: byte order marks, unmarked UTF-16, mostly-UTF-8, East Asian legacy encodings ranked by their standards' common characters, Windows-1252), never guessing Shift JIS, GB 18030 or Big5, whose trail bytes can hide a backslash; an encoding the file chose is not remembered. A mapping editor for CSV and JSON into an existing or new table, with Insert, Update, Insert or Update, and Insert, Skip Existing, matched on the primary key or a unique index as on macOS. "Delete existing rows first" empties the table and imports in one transaction (`IChangeTransactionProvider`), offered only for Insert as on macOS and only where the engine can hold that transaction. Every other row import also runs in one transaction by default, as macOS wraps it, behind the same "Wrap in transaction (BEGIN/COMMIT)" box: a failure leaves the table as it was, and the key counts for Update, Insert or Update, and Skip Existing run inside that transaction, so a key written earlier in the file is found. Unticked, or on an engine without `IChangeTransactionProvider`, each batch of 500 rows commits on its own, which the dialog says. Mappings are remembered per table and forgotten when their connection is deleted, and the transaction box opens on its last choice, as on macOS |
| Structure: columns, indexes, foreign keys, triggers | Built | |
| Structure editing: add, edit, rename, drop columns, add and drop indexes and foreign keys | Built | DDL is reviewed before it runs |
| Check constraints, partitions, table options editors | Built | PostgreSQL, MySQL and MariaDB, SQL Server, SQLite, DuckDB, Oracle, ClickHouse as each allows. No SQL Server partitions; an unpartitioned table cannot be partitioned |
| Definition view | Built | |
| Data Rewind, Compare and Sync | Built | Data compare of one table pair, a chosen set of tables or the whole schema, with each side's connection and schema, a per-table key, column, filter and row-limit scope, per-table counts, drill-in to a table's rows and one reviewed sync script ordered by foreign keys. A multi-table sync runs the whole script in one transaction, as macOS does, on every engine whose session offers `IChangeTransactionProvider` (the ADO.NET engines, ODBC, Snowflake and Spanner); with batches on, each batch is one transaction across tables. ClickHouse, Databend and the engines without transactions keep committing each table on its own, and the review sheet says so; macOS has the same limit there (LibSQL over HTTP and SurrealDB included). The tab reopens on the last setup as the macOS window does: options and mode always, the target and table scopes only when remembered against the same source connection, database and schema, and never over the table the tab was opened from. Saved comparison profiles reopen both sides, the scope and the options. On MySQL and MariaDB the review sheet names each table on a storage engine that ignores ROLLBACK (MyISAM, MEMORY, ARCHIVE and the like, read from `information_schema.TABLES` with bound names, against the macOS list of transactional engines), and a failed run that rolled back names the ones it wrote to, as macOS reports them. Schema compare with migration DDL, and an encrypted local journal that undoes grid saves. |

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
| Users and roles editing | Built | PostgreSQL, MySQL and MariaDB, SQL Server and Oracle: principals, attributes, memberships and grants at every scope, staged with undo and reviewed before apply. Typesense API keys are listed with their grants, created and deleted; keys cannot change, as on macOS. Several principals can be dropped together, and several objects of one kind granted on at once. Other engines list users only, as on macOS |
| Routine debugger | Built | PL/pgSQL through pldebugger and Oracle PL/SQL through DBMS_DEBUG, with breakpoints, stepping, call stack and variables. No DBMS_DEBUG_JDWP; not yet run against a server |
| Join builder, row generator, object copy between connections | Built | Foreign-key join suggestions on a canvas, seeded test data with foreign keys and unique columns, and copies that add foreign keys after the rows. A copy is not one transaction |
| Git and version history for SQL files, linked folders, team library | Built | Watched folders, local versions on save, Git log, diff, restore, commit, pull and push through git.exe. The team library shows in the SQL files pane while an active Team license grants it: pulled on activation and weekly, cleared on deactivation, saved queries published from Favorites. The welcome window lists the team's connections under Team Library and opens them unsaved, asking for the password each time, and publishes a saved connection from its menu without passwords, as macOS does |

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
| Licensing | Built | The macOS license service and rules: RSA-SHA256 payload checks with the macOS public key, activation by key or team invite, deactivation, seat release, machine binding to the SMBIOS UUID, weekly checks with 30 days offline grace, the key in Credential Manager, and Settings > License with devices, team roster and plans. Every paid feature is gated as on macOS, and follows a license activated or removed while open: the team library, including the team's connections on the welcome window; Result Charts behind an overlay with the upgrade prompt; Compare & Sync at its menu item, with open tabs and saved comparisons kept; Data Rewind journals no new saves and asks for the license at Restore, while kept saves stay listed; Export leaves credentials out, beside a plan badge |
| Crash log on disk | Built | `%LOCALAPPDATA%\TablePro\logs\errors.log` |
| Keyboard shortcut customization | Built | Settings > Keyboard records chords, warns about conflicts and applies at once; grid keys are fixed |
| Translations | Built | English, French, Korean, Turkish, Vietnamese, Simplified and Traditional Chinese, as on macOS, with a language picker in Settings > General. The app, Core, Storage, Ssh, Ai and the drivers all follow it; SQL, engine names, server text, logs and MCP stay English. Translations made for Windows alone await native review |
| Installer, MSIX package, winget, updates | Built | MSIX, a per-user zip installer, a windows-v* release workflow, a winget template and update checks with a beta channel. Signing needs the release certificate secret |
| Arm64 builds | Partial | The project builds for win-arm64; not tested on hardware |

## Before the first release

1. CI that builds the solution and runs every suite on Windows, plus driver suites against PostgreSQL, MySQL and SQL Server containers.
2. An installer or MSIX package with signing, and a `windows-v*` tag that publishes it.
3. A pass with Narrator and keyboard only, including the data grid.
4. Multiple cursors, which macOS users reach for daily.
