# Features

What the Linux app does, recorded on 2026-11-08. [0.1.0-beta.3](https://github.com/TableProApp/TablePro/releases/tag/linux-v0.1.0-beta.3) is published on GitHub Releases, the beta PPA, the beta COPR project and the beta Flatpak repository ([README](../README.md#betas)). beta.2 was tagged but never published: [release run 42382067978](https://github.com/TableProApp/TablePro/actions/runs/42382067978) failed before publishing, and [#4093](https://github.com/TableProApp/TablePro/pull/4093) fixed the failure for beta.3.

The work left and its order are in the repository's [ROADMAP.md](../../ROADMAP.md), and what 0.1.0 needs in the [release criteria](releasing.md#release-criteria).

The app runs on GNOME 50 ([ADR 0015](decisions/0015-gnome-50-platform-floor.md)) and connects to nine engines, each a crate linked in at compile time ([ADR 0001](decisions/0001-no-plugin-system.md)): [PostgreSQL](drivers/postgresql.md), [MySQL and MariaDB](drivers/mysql.md), [SQL Server](drivers/sql-server.md), [ClickHouse](drivers/clickhouse.md), [Cassandra and ScyllaDB](drivers/cassandra.md), [SQLite](drivers/sqlite.md), [DuckDB](drivers/duckdb.md), [Redis](drivers/redis.md) and [MongoDB](drivers/mongodb.md).


## Connections

| Capability | Detail |
|---|---|
| Saved connections | Create and edit (the name included), duplicate with the secrets carried to the copy, delete with or without the connection's history |
| Groups, favourites and colours | Groups nest 3 levels deep and show as a tree in the library's order, empty ones too. New Group, New Subgroup, Rename and Delete from the menus; a delete asks first. A connection or a group moves by drag and drop or from its menu (Move to Group, Move Group To, Move Up, Move Down). Favourites and the 5 connections opened last lead the picker; favourites reorder the same way |
| Tags and icons | Several named tags per connection, each with a colour, from the row's menu or the connect dialog, shown after the name and read with the row's description; Manage Tags renames, recolours and deletes them. An icon from a fixed set shows in the row and beside the window title |
| Search | The connection list's search (Ctrl+F, or start typing) matches the name, host, database, user, driver, the names on the group's path and tag names |
| Import and export | A JSON file with no secrets in it, tags and icons included. On import, an entry with the same id and the same settings updates its name, colour, group, tags and icon; any other is added as a new connection. Tags are matched by id, then by name, so a second import adds none |
| Connection URLs | A URL pasted at the top of a new connection fills the form: the engine, host, port, user, database and TLS mode, the authentication database, a DNS seed list and a replica set's hosts, and the password, kept in the Secret Service with Remember Password on. libpq, MySQL, MongoDB, Redis and Valkey, ClickHouse and Cassandra URLs, SQL Server's JDBC form and SQLite and DuckDB file URLs are read ([core `connection_url`](../../core/crates/core/src/connection_url/mod.rs)) |
| Unix sockets | PostgreSQL, MySQL and MariaDB on this computer through the server's socket, for peer, `auth_socket` and `unix_socket` logins: a folder for PostgreSQL, the socket file for MySQL, found in the distribution's usual place. The Flatpak sees the sockets under `/run/postgresql` and `/run/mysqld` ([ADR 0035](decisions/0035-flatpak-local-database-sockets.md)) |
| Test before saving | Test connects once and reports, then disconnects |
| Passwords | Kept in the Secret Service; a prompt asks when one is missing or refused, with Remember Password |
| Safe Mode | A level per connection, set in the connect dialog or the main menu while connected and saved back to the connection. Off asks before DROP, TRUNCATE, and DELETE or UPDATE without WHERE. Confirm Writes also asks before every other write from the editor, a grid save, a structure save, a CSV import, a SQL file import, or a drop, truncate or create from the sidebar, showing the SQL, or the file, and the connection, with Cancel the default. Read-Only refuses every editor statement that does not read, and opens the connection read-only: SQLite, DuckDB and ClickHouse refuse writes at the engine, PostgreSQL and MySQL run in read-only transactions, SQL Server relies on the login, with the app's own reads in a rolled-back transaction, and Cassandra and ScyllaDB rely on the login. A statement is a read only when its engine's grammar shows it reads, each statement of a script on its own. Moving to or from Read-Only reconnects the window |
| Query timeout per connection | Custom Query Timeout in the connect dialog sets the editor's timeout for that connection in place of the one in Preferences, from the next connect; 0 turns it off. The app's own calls keep their fixed limits: 15 seconds for metadata, 60 for a page or a count, 120 for a row save or a CSV import, none for a schema change or an export, and on the server 60 for a table-tab statement and 10 for a lock wait |
| Database files | SQLite and DuckDB: choose a file, create a new one, open one from Files or a terminal, where the file's header picks the engine, find a moved one with Locate, and choose read-only or read-write for one on a network or FUSE filesystem |
| Kerberos for SQL Server | From the ticket cache, in the Flatpak through the KCM socket |
| Health and reconnect | A banner while the connection is lost, reconnect with a backoff from 5 to 60 seconds, and metadata, page and count reads replayed once after it; writes are never replayed |
| Cancel on the server | Stopping a query stops the statement on the server (in process on SQLite); a ClickHouse mutation already running in a save is left to finish. CQL has no stop, so on Cassandra and ScyllaDB the app stops waiting and the server runs the statement to its own timeout |

## SSH

| Capability | Detail |
|---|---|
| System OpenSSH client | One ControlMaster per connection ([ADR 0013](decisions/0013-openssh-client-transport.md)); empty fields come from `~/.ssh/config` |
| Jump hosts | A ProxyJump chain, passed to `ssh -J` |
| Authentication | Agent, private key, password and keyboard-interactive; prompts go through the app's askpass helper |
| Host keys | An unknown or changed key is shown with its SHA256 fingerprint before connecting, even where ssh_config says accept-new or no. A changed key can be replaced in known_hosts, except under StrictHostKeyChecking yes, where the user fixes known_hosts outside the app and retries. A revoked key is refused |

## TLS

| Capability | Detail |
|---|---|
| Modes | Disable, Prefer (PostgreSQL and MySQL), Require and Verify full; a new connection starts on the mode the engine's own client starts on ([core ADR 0014](../../core/docs/decisions/0014-tls-mode-of-a-new-connection.md)) |
| Certificates | CA file, client certificate and key (every network engine but SQL Server), and a server name override (MySQL only through an SSH tunnel) |
| Remedies | A TLS failure says what went wrong. An unknown issuer jumps to the CA file, a name mismatch to the server name, and a server that refuses or requires TLS to the Encryption row |

## Browse and edit

| Capability | Detail |
|---|---|
| Data grid | A virtualized `GtkColumnView` with keyboard-focusable cells, pages of 100 to 10,000 rows, and a pager with an exact or estimated row count; a table of about 100,000 rows or fewer is counted on its own, a larger one offers Count Rows |
| Filters | Per-column operators, a raw WHERE fragment checked as one expression, match any or all; binary columns compare to `0x` hex. Kept per table, and per tab across a restart or a reopen. On Cassandra and ScyllaDB only the operators the server evaluates, matched all, with `ALLOW FILTERING` |
| Sorting | A header click sorts tables on the server and query results in the grid, one column at a time. A Cassandra or ScyllaDB table keeps the server's order, and pages by its paging state |
| Cell editing | Editors by column kind: inline text, a multi-line editor, a calendar for dates and, in Row Details, a clock for times, a toggle for booleans, JSON checked before saving; values are edited from their exact text, never from what the cell displays. Tables with a primary key, in a table tab or as a query result that reads one table with its whole key ([ADR 0036](decisions/0036-editing-query-results.md)); key, generated and auto-increment columns, and binary, spatial, array and composite values, are read-only |
| Rows | Insert, duplicate and delete; Paste (Ctrl+V) adds tab-separated rows from the clipboard, filling the columns from the focused one or by a header's names, or edits the focused cell with one value, and asks first above 1,000 rows, up to 100,000; Set NULL and Empty, and DEFAULT on a new row; undo and redo; save or discard pending changes, and stop a save. On ClickHouse, Cassandra and ScyllaDB a save is not atomic, and Stop takes effect between statements |
| Server-computed values | A date, time or timestamp cell takes the engine's own `NOW()`, `CURRENT_TIMESTAMP`, `CURRENT_DATE` and the like, typed in any letter case or picked from the cell menu, and a saved row's cell takes DEFAULT where the engine has `SET c = DEFAULT` (PostgreSQL, MySQL and MariaDB, SQL Server, DuckDB). Only each engine's own list is offered, which on DuckDB is `now()` alone, since the bundled build has no ICU extension; the save writes the expression into the statement, so the Confirm Writes review and the history show it as written |
| Bulk delete | Deleting 10 rows or more asks first, unless Confirm Before Deleting Rows is off in Preferences |
| Copy | Copy; Copy As rows, with headers, CSV with or without headers, JSON, JSON Lines, Markdown, a text table, IN clause or one row of SQL values, and INSERT with or without generated keys in an editable table tab; Copy Column Name; Show Row as JSON |
| Foreign keys | Open Referenced Row (Ctrl+J) on a key cell opens the table it points at in a new tab, filtered on every column of the key; Show Referencing Rows on a saved row opens a table whose key points at it. A tab already showing those rows comes to the front |
| Column layout | Order, hidden columns and widths kept per table; a column added since goes last and a dropped one keeps its place. A header drag, or Move Column Left and Move Column Right in the cell menu (Alt+Left and Alt+Right), reorders them; Widen Column and Narrow Column (Shift+Alt+Right and Shift+Alt+Left) resize them; Reset Columns in the Columns dialog goes back to the table's own order |
| CSV import | Into an existing table, with a column mapping, in one write batch (one transaction where the engine has them), up to 64 MiB |
| Sidebar | Tables (partitioned ones included), views, materialized views and foreign tables by schema, with search and Refresh, read again after the editor runs DDL, Open in New Tab and Show CREATE TABLE; Edit Structure, Import CSV, Truncate Table and Drop Table for tables, Delete All Documents for collections; New and Drop Schema, and New and Drop Database (Keyspace on Cassandra), on every engine that has them, never offered for a system object or the session's own database; empty schemas listed |
| Routines and triggers | Functions, procedures and sequences in the sidebar after each schema's tables, and triggers with the table each fires on, on every engine that has them. Opening one shows its definition read-only, with Copy and Open in Editor; every overload of a PostgreSQL function name is shown |
| ER diagram | Show ER Diagram in a table's menu or on a schema's heading opens the schema's tables as cards and their foreign keys as lines in crow's foot notation, read two tables at a time with Stop. Pan, zoom, Best Fit, drag tables, Reset Layout, and PNG and SVG export. Each table is a list item the keyboard and a screen reader reach: Tab and the arrow keys move between tables, Enter opens one, Alt+arrows move it, and its description names its columns and the tables it joins |

## Structure

| Capability | Detail |
|---|---|
| Table definition | Columns, indexes, foreign keys and column comments |
| Index statements | Show CREATE INDEX and Copy CREATE INDEX on each index the table has, as the statement that makes it again: the server's own text on PostgreSQL, MySQL, MariaDB, SQLite and DuckDB, and written from the catalog, storage and options included, on SQL Server, ClickHouse, Cassandra and ScyllaDB. An index a constraint owns, such as a primary key or a UNIQUE constraint, a partition's index attached to its parent's and a ClickHouse sorting key offer none. Show CREATE TABLE uses the same statements |
| Changes | Create, rename and drop tables; add, drop and rename columns, and change their type, nullability, default, comment, primary key and auto-increment; add and drop indexes (column keys, unique, descending) and foreign keys. ClickHouse creates no tables, indexes or foreign keys and changes no primary key or auto-increment; SQL Server changes no auto-increment; SQLite keeps no column comments; Cassandra and ScyllaDB take no default or NOT NULL, and rename only key columns |
| Review | The SQL is previewed, and a save that loses data or can stop halfway is reviewed before it runs |
| SQLite rebuilds | Changes SQLite cannot ALTER rebuild the table in one transaction, keeping its rows, indexes, triggers, the views and triggers that name it and its AUTOINCREMENT counter, with foreign keys checked before commit. SQLite itself checks the views and triggers made again; a trigger that lists a dropped column or inserts by position is refused before Save |

## Keys

| Capability | Detail |
|---|---|
| Key list | A Redis connection lists the keys of its numbered database with their types, read with `SCAN`; the search goes to the server, plain text matching anywhere in a key and text with `*`, `?` or `[` as a glob. A banner says when the list stops at its 5,000-key limit |
| Key tab | A key opens by type: a string's value, a hash's fields, a list by index, a set's members, a sorted set with scores and a stream's entries, 500 at a time with Load More, under its length and expiry |
| Commands | The editor takes Redis commands, one per line, and shows each reply as redis-cli lays it out; `MULTI` is tracked as a transaction. A waiting command stops with `CLIENT UNBLOCK`. Read-Only refuses every command that is not a read before it is sent ([redis.md](drivers/redis.md)) |

## Documents

| Capability | Detail |
|---|---|
| Connecting | A MongoDB connection reaches one host directly, a replica set from its hosts and name, a replica set or cluster through its DNS seed list (`mongodb+srv://`), or one host through SSH, with an optional authentication database |
| Collections | Databases list their collections and views. A collection opens in a table tab: its top-level fields as columns, `_id` first, nested documents and arrays as JSON. Paging, filters, the raw filter as a query document, sorting, editing a field, inserting and deleting run as mongosh calls with bound values, shown in the history and the Safe Mode review ([mongodb.md](drivers/mongodb.md)) |
| Statements | The editor takes mongosh statements (`find`, `aggregate`, the writes, `runCommand`, `use`, `show`) and shows documents one per row. A running statement stops with `killSessions`. Read-Only refuses every statement that is not a read, `$out` and `$merge` included, before it is sent |

## SQL editor

| Capability | Detail |
|---|---|
| Editing | GtkSourceView with SQL highlighting, a scheme that follows the light or dark style, and toggle comment |
| Completion | Tables, views, columns, schemas, functions and keywords, with aliases resolved |
| Snippets | SELECT, INSERT, UPDATE, DELETE, a join (none on Cassandra and ScyllaDB), CREATE TABLE and CREATE INDEX per engine, and the user's own in GtkSourceView's format from a folder read again when it changes, a snippet scoped to one engine or to all; offered in completion, with Tab between stops ([README](../README.md#snippets)) |
| Formatter | Format SQL, leaving a statement as typed when formatting would change its tokens |
| Scripts | Split per dialect (`DELIMITER`, `GO` and `GO n`, routine and trigger bodies) and sent a statement at a time, or a batch at a time on SQL Server; each result set, row count, notice or error is its own entry, and a failure stops the script except on SQL Server. Run Selection, and run the statement at the cursor |
| Find and replace | Ctrl+F and Ctrl+H, with case, whole word and regular expressions |
| Files | Open a .sql file into the editor (Ctrl+O) or drop one on it, and save to it (Ctrl+S, or Save As with Ctrl+Shift+S) |
| Results | Several result sets per run, a limit of 10,000 rows per result and 100,000 per run with a banner and Export All, and Go to Error |
| Drafts | Each editor tab's text is kept, and a connection's tabs (table tabs with page and sort, structure and editor tabs) reopen when it opens |
| Multiple cursors | Ctrl+D for the next match, Ctrl+Shift+L for every match, Shift+Alt+Up and Down for the lines above and below, Ctrl+click; typing, deleting, pasting and moves at every cursor, one undo for all of them ([README](../README.md#multiple-cursors)) |
| Vim mode | GtkSourceView's Vim emulation, off by default, with the mode and pending command under the text; `:w`, `:e`, `:q`, `:wq` and `:x` act on the tab, and the editor's Ctrl shortcuts work in every mode ([README](../README.md#vim-keybindings)) |

## History and saved queries

| Capability | Detail |
|---|---|
| Query history | A SQLite database with full-text search, filters by connection, time and status, pins, export as SQL or CSV, and a retention period |
| What is recorded | Editor runs, and the SQL the app runs for grid saves, structure saves and successful imports; a run that can carry a password or connection secret, or whose text does not tokenize, is not recorded, and recording can be turned off |
| Show in Files | For the history database, from the history dialog and Preferences |
| Saved queries | Saved from the editor against a connection, listed by connection with the active one first, and opened in a new tab or the current one |

## Export

| Capability | Detail |
|---|---|
| Formats | CSV with its options, JSON, Markdown, HTML, XML, Excel, and SQL INSERT from a table tab |
| Scope | From a table tab, the current page with its pending edits, or every saved row under the filter and sort. From the editor, the rows shown, or every row by running the statement again on a separate read-only connection without the tab's USE or SET; a statement that writes is refused |
| Running | Off the GTK thread with progress and Stop; closing or quitting asks about a running export |
| Database | Export Database in the main menu writes a whole database or one schema to a `.sql` or `.sql.gz` file: tables, views, routines and triggers, and every table's rows as multi-row INSERTs, in the order `pg_dump` and `mysqldump` use, so `psql`, `mysql`, `sqlcmd`, `sqlite3` and `clickhouse-client` load it as well as Import SQL File does. Read in process from the connection, not by calling those tools ([core ADR 0011](../../core/docs/decisions/0011-sql-dump-and-import-in-process.md)); not offered on Redis, MongoDB, Cassandra and ScyllaDB ([README](../README.md#export-a-database-and-import-a-sql-file)) |

## Import

| Capability | Detail |
|---|---|
| SQL files | Import SQL File in the main menu runs a `.sql` or `.sql.gz` file of any size on an editor session of its own, split as the engine's client splits it (`DELIMITER`, `GO n`, routine bodies, dollar quotes), with progress, Stop and a summary of what failed and where. pg_dump's `COPY ... FROM stdin` rows load through the copy protocol, text or CSV, and its `\restrict` lines are passed over |
| Errors and transactions | Stop at First Error, or run the rest and list each failure with its line. On PostgreSQL, SQL Server, SQLite and DuckDB the file can run as one transaction, so a failure or Stop undoes it all; MySQL, MariaDB and ClickHouse commit each statement as it runs. Safe Mode Read-Only offers neither import, and the import dialog is the one question Confirm Writes asks for the whole file |

## Windows and sessions

| Capability | Detail |
|---|---|
| Sessions in a window | A window holds several connection sessions, their tabs side by side in one tab view, and a connection already open brings its window forward ([ADR 0028](decisions/0028-sessions-share-a-window.md)) |
| One instance | A second launch presents the running app; New Window (Ctrl+Shift+N) opens a picker |
| Tabs | `AdwTabView` with the tab overview and split header bars, adapting down to 360×294 |
| Session restore | The windows of saved connections and database files open at quit open again at launch (Restore Session, on by default), also after New Window or a quit during the restore |
| Closing safely | Unsaved edits, a save in flight or of unknown outcome, an open editor transaction, or a running export ask before a window closes or the app quits; logout waits while any of those holds, and suspend while a save runs or an export writes |
| Notifications | Work that finishes in a tab you are not looking at sends a notification |
| Preferences | Restore session, page size, the bulk delete confirmation, query history, editor font and scheme, Vim keybindings, query timeout, the AI assistant, the MCP server |
| Shortcuts and About | A shortcuts dialog, and About from the metainfo with third-party licenses and debug info |

## AI assistant

| Capability | Detail |
|---|---|
| Providers | Off until a provider is chosen in Preferences: Anthropic, OpenAI, or Ollama and other servers through the OpenAI-compatible protocol. Keys in the keyring; the model picked from the provider's list ([ADR 0022](decisions/0022-ai-assistant-and-mcp-server.md)) |
| Chat | A pane beside the tabs (Ctrl+Alt+A) with streamed replies, Stop, Retry and New Conversation; code blocks with Copy and Insert. A conversation carries the editor's SQL and the structure of the tables it names, and reads no rows |
| Editor | Explain, Review and Optimize the selection or the statement at the cursor, Fix with AI on a failed statement, and suggestions while typing (off by default) that Tab accepts |
| AI policy | Per connection: Ask Each Time (the default) asks before the first request in a window, Allow sends without asking, Never sends nothing from the connection |

## MCP server

| Capability | Detail |
|---|---|
| Server | Streamable HTTP on `127.0.0.1` only, off until turned on in Preferences, with a port preference and a bearer token kept in the keyring ([ADR 0022](decisions/0022-ai-assistant-and-mcp-server.md)) |
| External Clients | A level per connection: Blocked hides it, Read Only (the default) lets clients read, Read & Write lets them write after the user approves each statement in Safe Mode's dialog. Safe Mode Read-Only refuses every client write |
| Tools | List connections, open one in a window, list schemas and tables, describe a table and show its DDL, browse and count rows with filters, and run one statement; runs go into the query history |

## TablePro account

| Capability | Detail |
|---|---|
| Sign-in | Preferences > Account signs in to a TablePro account through the browser, as on macOS; the sign-in is kept in the keyring ([ADR 0038](decisions/0038-account-page-and-license-ask.md)) |
| Plan, devices and teams | The plan and its status, each paid feature this platform has, included or not by the plan ([ADR 0042](decisions/0042-account-page-lists-this-platforms-features.md)), the account's devices with Remove, the device limit dialog, teams, and offline files for a computer with no internet |
| License ask | From the 30th day of use without a license, a toast asks whether you would buy one, then at most every 90 days |
| Usage data | On by default, as on macOS: the clients.md events go to PostHog until Preferences > General > Privacy turns it off ([ADR 0039](decisions/0039-usage-data.md)) |

## Packaging and platform

| Capability | Detail |
|---|---|
| Flatpak | The Devel manifest builds on GNOME 51 for x86_64 and aarch64 with every Meson suite in the sandbox, and is linted, in the nightly Linux run; the release manifest builds the Flatpak a release signs into `flatpak.tablepro.app` and bundles for GitHub, offline from the release tarballs; CI tests it, signs it into test repositories, then installs, starts, updates and switches branches on Ubuntu 22.04, 24.04 and 26.04 ([ADR 0041](decisions/0041-beta-repositories-and-release-packages.md)) |
| .deb and .rpm | Ubuntu 26.04 and 26.10 and Fedora 44 and 45, built offline in CI the way Launchpad and COPR build them, linted, then installed and started in fresh containers; a `linux-v*` tag publishes them on GitHub Releases, uploads to the PPA and starts the COPR build, a beta tag to the beta ones ([ADR 0018](decisions/0018-ppa-copr-and-flathub-later.md), [ADR 0041](decisions/0041-beta-repositories-and-release-packages.md)) |
| Desktop integration | Desktop file with Open With for SQLite files, D-Bus activation, a man page, metainfo with screenshots, and SVG icons |
| Translations | Vietnamese ships. The app's own strings go through gettext, and CI fails when `POTFILES.in` is stale or a translation loses a placeholder. CI builds the template with gettext 1.0 and publishes it from main and with each release; translators send pull requests against `po/*.po` ([po/README.md](../po/README.md#where-translators-work)) |
| Logs | stderr, which the session journals, with JSON lines on request. A panic also writes a crash report under `$XDG_STATE_HOME`, offered with Show Report on the next launch |
| Tests | Unit, gtk (with an accessibility audit of the picker, the connect pages, the workspace, the connect dialog and every preferences page), data and packaging suites; connection, DDL and TLS conformance, a CSV and SQL INSERT export round trip, a copy and paste round trip, and a database dump loaded back through Import SQL File and dumped again to the same file, on every SQL engine, keyspace and TLS conformance on Redis, and document and TLS conformance on MongoDB; Docker jobs for PostgreSQL with PgBouncer, MySQL and MariaDB, SQL Server, ClickHouse, Cassandra and ScyllaDB, Redis, MongoDB, SSH, the session and the grid save ([testing.md](testing.md)); every critical audit finding has named guards ([regression-tests.md](regression-tests.md)) |
