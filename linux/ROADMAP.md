# Roadmap

**Status, 2026-10-19**: every capability in the tables below is in the tree. Nothing has shipped yet: no `linux-v*` tag has been cut. The [release criteria](#release-criteria) say what has to hold first, and the [backlog](#backlog) lists what is not built.

The app runs on GNOME 50 ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) and connects to nine engines, each a crate linked in at compile time ([ADR 0001](docs/decisions/0001-no-plugin-system.md)): [PostgreSQL](docs/drivers/postgresql.md), [MySQL and MariaDB](docs/drivers/mysql.md), [SQL Server](docs/drivers/sql-server.md), [ClickHouse](docs/drivers/clickhouse.md), [Cassandra and ScyllaDB](docs/drivers/cassandra.md), [SQLite](docs/drivers/sqlite.md), [DuckDB](docs/drivers/duckdb.md), [Redis](docs/drivers/redis.md) and [MongoDB](docs/drivers/mongodb.md).

## Implemented

### Connections

| Capability | Detail |
|---|---|
| Saved connections | Create and edit (the name included), duplicate with the secrets carried to the copy, delete with or without the connection's history |
| Groups and colours | From the connection row's menu; each group is a section of the connection list |
| Tags and icons | Several named tags per connection, each with a colour, from the row's menu or the connect dialog, shown after the name and read with the row's description; Manage Tags renames, recolours and deletes them. An icon from a fixed set shows in the row and beside the window title |
| Search | The connection list's search (Ctrl+F, or start typing) matches the name, host, database, user, driver, group and tag names |
| Import and export | A JSON file with no secrets in it, tags and icons included. On import, an entry with the same id and the same settings updates its name, colour, group, tags and icon; any other is added as a new connection. Tags are matched by id, then by name, so a second import adds none |
| Test before saving | Test connects once and reports, then disconnects |
| Passwords | Kept in the Secret Service; a prompt asks when one is missing or refused, with Remember Password |
| Safe Mode | A level per connection, set in the connect dialog or the main menu while connected and saved back to the connection. Off asks before DROP, TRUNCATE, and DELETE or UPDATE without WHERE. Confirm Writes also asks before every other write from the editor, a grid save, a structure save, a CSV import or Drop Table, showing the SQL and the connection, with Cancel the default. Read-Only refuses every editor statement that does not read, and opens the connection read-only: SQLite, DuckDB and ClickHouse refuse writes at the engine, PostgreSQL and MySQL run in read-only transactions, SQL Server relies on the login, with the app's own reads in a rolled-back transaction, and Cassandra and ScyllaDB rely on the login. A statement is a read only when its engine's grammar shows it reads, each statement of a script on its own. Moving to or from Read-Only reconnects the window |
| Database files | SQLite and DuckDB: choose a file, create a new one, open one from Files or a terminal, where the file's header picks the engine, find a moved one with Locate, and choose read-only or read-write for one on a network or FUSE filesystem |
| Kerberos for SQL Server | From the ticket cache, in the Flatpak through the KCM socket |
| Health and reconnect | A banner while the connection is lost, reconnect with a backoff from 5 to 60 seconds, and metadata, page and count reads replayed once after it; writes are never replayed |
| Cancel on the server | Stopping a query stops the statement on the server (in process on SQLite); a ClickHouse mutation already running in a save is left to finish. CQL has no stop, so on Cassandra and ScyllaDB the app stops waiting and the server runs the statement to its own timeout |

### SSH

| Capability | Detail |
|---|---|
| System OpenSSH client | One ControlMaster per connection ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)); empty fields come from `~/.ssh/config` |
| Jump hosts | A ProxyJump chain, passed to `ssh -J` |
| Authentication | Agent, private key, password and keyboard-interactive; prompts go through the app's askpass helper |
| Host keys | An unknown or changed key is shown with its SHA256 fingerprint before connecting, even where ssh_config says accept-new or no. A changed key can be replaced in known_hosts, except under StrictHostKeyChecking yes, where the user fixes known_hosts outside the app and retries. A revoked key is refused |

### TLS

| Capability | Detail |
|---|---|
| Modes | Disable, Require and Verify full; Verify full is the default for a new connection |
| Certificates | CA file, client certificate and key (every network engine but SQL Server), and a server name override (MySQL only through an SSH tunnel) |
| Remedies | A TLS failure says what went wrong. An unknown issuer jumps to the CA file, and a name mismatch to the server name |

### Browse and edit

| Capability | Detail |
|---|---|
| Data grid | A virtualized `GtkColumnView` with keyboard-focusable cells, pages of 100 to 10,000 rows, and a pager with an exact or estimated row count; a table of about 100,000 rows or fewer is counted on its own, a larger one offers Count Rows |
| Filters | Per-column operators, a raw WHERE fragment checked as one expression, match any or all; binary columns compare to `0x` hex. Kept per table, and per tab across a restart or a reopen. On Cassandra and ScyllaDB only the operators the server evaluates, matched all, with `ALLOW FILTERING` |
| Sorting | A header click sorts tables on the server and query results in the grid, one column at a time. A Cassandra or ScyllaDB table keeps the server's order, and pages by its paging state |
| Cell editing | Editors by column kind: inline text, a multi-line editor, a calendar for dates, a toggle for booleans, JSON checked before saving; values are edited from their exact text, never from what the cell displays. Table tabs only, on tables with a primary key; key, generated and auto-increment columns, and binary, spatial, array and composite values, are read-only |
| Rows | Insert, duplicate and delete; Paste (Ctrl+V) adds tab-separated rows from the clipboard, filling the columns from the focused one or by a header's names, or edits the focused cell with one value, and asks first above 1,000 rows, up to 100,000; Set NULL and Empty, and DEFAULT on a new row; undo and redo; save or discard pending changes, and stop a save. On ClickHouse, Cassandra and ScyllaDB a save is not atomic, and Stop takes effect between statements |
| Bulk delete | Deleting 10 rows or more asks first, unless Confirm Before Deleting Rows is off in Preferences |
| Copy | Copy; Copy As rows, with headers, JSON, CSV with or without headers, Markdown or IN clause, and INSERT in an editable table tab; Copy Column Name; Show Row as JSON |
| Foreign keys | Open Referenced Row (Ctrl+J) on a key cell opens the table it points at in a new tab, filtered on every column of the key; Show Referencing Rows on a saved row opens a table whose key points at it. A tab already showing those rows comes to the front |
| Column widths | Kept per table; Widen Column and Narrow Column in the cell menu (Shift+Alt+Right and Shift+Alt+Left) change them from the keyboard |
| CSV import | Into an existing table, with a column mapping, in one write batch (one transaction where the engine has them), up to 64 MiB |
| Sidebar | Tables (partitioned ones included), views, materialized views and foreign tables by schema, with search and Refresh, read again after the editor runs DDL, Open in New Tab and Show CREATE TABLE; Edit Structure, Import CSV and Drop Table for tables |
| ER diagram | Show ER Diagram in a table's menu or on a schema's heading opens the schema's tables as cards and their foreign keys as lines in crow's foot notation, read two tables at a time with Stop. Pan, zoom, Best Fit, drag tables, Reset Layout, and PNG and SVG export. Each table is a list item the keyboard and a screen reader reach: Tab and the arrow keys move between tables, Enter opens one, Alt+arrows move it, and its description names its columns and the tables it joins |

### Structure

| Capability | Detail |
|---|---|
| Table definition | Columns, indexes, foreign keys and column comments |
| Changes | Create, rename and drop tables; add, drop and rename columns, and change their type, nullability, default, comment, primary key and auto-increment; add and drop indexes (column keys, unique, descending) and foreign keys. ClickHouse creates no tables, indexes or foreign keys and changes no primary key or auto-increment; SQL Server changes no auto-increment; SQLite keeps no column comments; Cassandra and ScyllaDB take no default or NOT NULL, and rename only key columns |
| Review | The SQL is previewed, and a save that loses data or can stop halfway is reviewed before it runs |
| SQLite rebuilds | Changes SQLite cannot ALTER rebuild the table in one transaction, keeping its rows, indexes, triggers, the views and triggers that name it and its AUTOINCREMENT counter, with foreign keys checked before commit. SQLite itself checks the views and triggers made again; a trigger that lists a dropped column or inserts by position is refused before Save |

### Keys

| Capability | Detail |
|---|---|
| Key list | A Redis connection lists the keys of its numbered database with their types, read with `SCAN`; the search goes to the server, plain text matching anywhere in a key and text with `*`, `?` or `[` as a glob. A banner says when the list stops at its 5,000-key limit |
| Key tab | A key opens by type: a string's value, a hash's fields, a list by index, a set's members, a sorted set with scores and a stream's entries, 500 at a time with Load More, under its length and expiry |
| Commands | The editor takes Redis commands, one per line, and shows each reply as redis-cli lays it out; `MULTI` is tracked as a transaction. A waiting command stops with `CLIENT UNBLOCK`. Read-Only refuses every command that is not a read before it is sent ([redis.md](docs/drivers/redis.md)) |

### Documents

| Capability | Detail |
|---|---|
| Connecting | A MongoDB connection reaches one host directly, a replica set or cluster through its DNS seed list (`mongodb+srv://`), or one host through SSH, with an optional authentication database |
| Collections | Databases list their collections and views. A collection opens in a table tab: its top-level fields as columns, `_id` first, nested documents and arrays as JSON. Paging, filters, the raw filter as a query document, sorting, editing a field, inserting and deleting run as mongosh calls with bound values, shown in the history and the Safe Mode review ([mongodb.md](docs/drivers/mongodb.md)) |
| Statements | The editor takes mongosh statements (`find`, `aggregate`, the writes, `runCommand`, `use`, `show`) and shows documents one per row. A running statement stops with `killSessions`. Read-Only refuses every statement that is not a read, `$out` and `$merge` included, before it is sent |

### SQL editor

| Capability | Detail |
|---|---|
| Editing | GtkSourceView with SQL highlighting, a scheme that follows the light or dark style, and toggle comment |
| Completion | Tables, views, columns, schemas, functions and keywords, with aliases resolved |
| Snippets | SELECT, INSERT, UPDATE, DELETE, a join (none on Cassandra and ScyllaDB), CREATE TABLE and CREATE INDEX per engine, and the user's own in GtkSourceView's format from a folder read again when it changes, a snippet scoped to one engine or to all; offered in completion, with Tab between stops ([README](README.md#snippets)) |
| Formatter | Format SQL, leaving a statement as typed when formatting would change its tokens |
| Scripts | Split per dialect (`DELIMITER`, `GO` and `GO n`, routine and trigger bodies) and sent a statement at a time, or a batch at a time on SQL Server; each result set, row count, notice or error is its own entry, and a failure stops the script except on SQL Server. Run Selection, and run the statement at the cursor |
| Find and replace | Ctrl+F and Ctrl+H, with case, whole word and regular expressions |
| Files | Open a .sql file into the editor (Ctrl+O) or drop one on it, and save to it (Ctrl+S, or Save As with Ctrl+Shift+S) |
| Results | Several result sets per run, a limit of 10,000 rows per result and 100,000 per run with a banner and Export All, and Go to Error |
| Drafts | Each editor tab's text is kept, and a connection's tabs (table tabs with page and sort, structure and editor tabs) reopen when it opens |
| Multiple cursors | Ctrl+D for the next match, Ctrl+Shift+L for every match, Shift+Alt+Up and Down for the lines above and below, Ctrl+click; typing, deleting, pasting and moves at every cursor, one undo for all of them ([README](README.md#multiple-cursors)) |
| Vim mode | GtkSourceView's Vim emulation, off by default, with the mode and pending command under the text; `:w`, `:e`, `:q`, `:wq` and `:x` act on the tab, and the editor's Ctrl shortcuts work in every mode ([README](README.md#vim-keybindings)) |

### History and saved queries

| Capability | Detail |
|---|---|
| Query history | A SQLite database with full-text search, filters by connection, time and status, pins, export as SQL or CSV, and a retention period |
| What is recorded | Editor runs, and the SQL the app runs for grid saves, structure saves and successful imports; a run that can carry a password or connection secret, or whose text does not tokenize, is not recorded, and recording can be turned off |
| Show in Files | For the history database, from the history dialog and Preferences |
| Saved queries | Saved from the editor against a connection, listed by connection with the active one first, and opened in a new tab or the current one |

### Export

| Capability | Detail |
|---|---|
| Formats | CSV with its options, JSON, Markdown, HTML, XML, Excel, and SQL INSERT from a table tab |
| Scope | From a table tab, the current page with its pending edits, or every saved row under the filter and sort. From the editor, the rows shown, or every row by running the statement again on a separate read-only connection without the tab's USE or SET; a statement that writes is refused |
| Running | Off the GTK thread with progress and Stop; closing or quitting asks about a running export |

### Windows and sessions

| Capability | Detail |
|---|---|
| Window per session | A window holds one connection; another connection opens in a window of its own, and one already open brings its window forward ([ADR 0012](docs/decisions/0012-window-per-session.md)) |
| One instance | A second launch presents the running app; New Window (Ctrl+Shift+N) opens a picker |
| Tabs | `AdwTabView` with the tab overview and split header bars, adapting down to 360×294 |
| Session restore | The windows of saved connections and database files open at quit open again at launch (Restore Session, on by default), also after New Window or a quit during the restore |
| Closing safely | Unsaved edits, a save in flight or of unknown outcome, an open editor transaction, or a running export ask before a window closes or the app quits; logout waits while any of those holds, and suspend while a save runs or an export writes |
| Notifications | Work that finishes in a tab you are not looking at sends a notification |
| Preferences | Restore session, page size, the bulk delete confirmation, query history, editor font and scheme, Vim keybindings, query timeout, the AI assistant, the MCP server |
| Shortcuts and About | A shortcuts dialog, and About from the metainfo with third-party licenses and debug info |

### AI assistant

| Capability | Detail |
|---|---|
| Providers | Off until a provider is chosen in Preferences: Anthropic, OpenAI, or Ollama and other servers through the OpenAI-compatible protocol. Keys in the keyring; the model picked from the provider's list ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)) |
| Chat | A pane beside the tabs (Ctrl+Alt+A) with streamed replies, Stop, Retry and New Conversation; code blocks with Copy and Insert. A conversation carries the editor's SQL and the structure of the tables it names, and reads no rows |
| Editor | Explain, Review and Optimize the selection or the statement at the cursor, Fix with AI on a failed statement, and suggestions while typing (off by default) that Tab accepts |
| AI policy | Per connection: Ask Each Time (the default) asks before the first request in a window, Allow sends without asking, Never sends nothing from the connection |

### MCP server

| Capability | Detail |
|---|---|
| Server | Streamable HTTP on `127.0.0.1` only, off until turned on in Preferences, with a port preference and a bearer token kept in the keyring ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)) |
| External Clients | A level per connection: Blocked hides it, Read Only (the default) lets clients read, Read & Write lets them write after the user approves each statement in Safe Mode's dialog. Safe Mode Read-Only refuses every client write |
| Tools | List connections, open one in a window, list schemas and tables, describe a table and show its DDL, browse and count rows with filters, and run one statement; runs go into the query history |

### Packaging and platform

| Capability | Detail |
|---|---|
| Flatpak | The Devel manifest builds on GNOME 51 for x86_64 and aarch64 with every Meson suite in the sandbox, and is linted, in the nightly Linux run |
| .deb and .rpm | Ubuntu 26.04 and 26.10 and Fedora 44, built offline in CI the way Launchpad and COPR build them, linted, then installed and started in fresh containers; a `linux-v*` tag uploads to the PPA and starts the COPR build ([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md)) |
| Desktop integration | Desktop file with Open With for SQLite files, D-Bus activation, a man page, metainfo with screenshots, and SVG icons |
| Translations | Vietnamese ships. The app's own strings go through gettext, and CI fails when `POTFILES.in` is stale or a translation loses a placeholder. CI builds the template with gettext 1.0 and publishes it from main and with each release; translators send pull requests against `po/*.po` ([po/README.md](po/README.md#where-translators-work)) |
| Logs | stderr, which the session journals, with JSON lines on request. A panic also writes a crash report under `$XDG_STATE_HOME`, offered with Show Report on the next launch |
| Tests | Unit, gtk (with an accessibility audit of the picker, the connect pages, the workspace, the connect dialog and every preferences page), data and packaging suites; connection, DDL and TLS conformance, and a CSV and SQL INSERT export round trip and a copy and paste round trip, on every SQL engine, keyspace and TLS conformance on Redis, and document and TLS conformance on MongoDB; Docker jobs for PostgreSQL with PgBouncer, MySQL and MariaDB, SQL Server, ClickHouse, Cassandra and ScyllaDB, Redis, MongoDB, SSH, the session and the grid save ([testing.md](docs/testing.md)); every critical audit finding has named guards ([regression-tests.md](docs/regression-tests.md)) |

## Backlog

Not built yet, in no order.

### Connections

- A statement timeout per connection. Today one preference covers editor runs. Other calls have fixed limits: 15 seconds for metadata, 60 for a page or a count, 120 for a row save or a CSV import, and none for a schema change or an export; the server also stops any table-tab statement at 60 seconds and a lock wait at 10.
- Kerberos against a service outside the client's realm, which needs an SPN override in tiberius.

### Browse, edit and structure

- Set a cell to `NOW()` or `CURRENT_TIMESTAMP`, which needs SQL expressions as cell values.
- Edit binary columns from and to a file. They are read-only today, as are array, spatial, composite and variant columns.
- Time and timestamp pickers. Dates have a calendar; times and timestamps are typed.
- Save the column order per table.
- Functions, procedures, sequences and triggers in the sidebar. The drivers already list the first three.
- The CREATE INDEX statement for one index. Show CREATE TABLE lists them after the table on PostgreSQL, SQL Server and SQLite (with the triggers on SQLite).
- Reorder columns in the structure tab by dragging, with the ALTER previewed.

### Release and project

- Before the first tag, the release setup [ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md#consequences) lists: the PPA, the COPR project, and the secrets and variable `release-linux.yml` names in its header.
- Write the Flathub manifest and the exception request by hand, and submit them.
- An AUR PKGBUILD, kept by the community.
- More languages: French, Korean, Turkish, and Simplified and Traditional Chinese, which the macOS app ships.
- A manual pass with Orca, the keyboard alone, High Contrast, 1.5x text scaling and a right-to-left locale.
- Install and use it on Ubuntu 26.04 and Fedora 44 by hand, and under KDE Plasma with the Adwaita style.
- A Linux user guide on docs.tablepro.app, a page on the marketing site, and a support channel.

### More engines

Each one is a crate under `crates/drivers` ([adding-drivers.md](docs/adding-drivers.md)), on a client library that meets [adding-drivers.md, The client library](docs/adding-drivers.md#1-the-client-library): maintained on crates.io, TLS through aws-lc-rs, a stream or Unix socket transport for SSH, and a way to stop a statement.

| Engine | Client | Condition |
|---|---|---|
| Oracle | none | Blocked. The oracle crate has one maintainer, no release since 2025-01-02, and needs the proprietary Oracle client |

Microsoft's mssql-tds is checked again each release as a SQL Server client. Today its TLS on Linux goes through OpenSSL and it takes no outside pull requests, so tiberius stays.

### Ideas

Not committed: server monitoring (sessions, locks, slow queries), maintenance commands, backup and restore, replication status, comparing result sets, schema diff and data sync between connections, drawn query plans, scheduled queries, and opt-in usage telemetry.

## Release criteria

What has to hold before the first release, for a user on GNOME 50 with Ubuntu 26.04 or Fedora 44, and where each stands on 2026-10-19:

| # | The user | Holds today | Still needed |
|---|---|---|---|
| 1 | Installs `tablepro` from the PPA or the COPR project, and gets updates from the system's updater | CI builds both packages offline the way Launchpad and COPR do, and starts them in fresh containers | The release setup, the first tag, and an install then an upgrade from the PPA and COPR |
| 2 | Connects to their everyday PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB or SQLite database | The supported releases and why others are out, in the README's [supported servers](README.md#supported-servers). CI runs every driver's Docker suite on each tested release, MySQL 8.0 and SQL Server 2017 and 2019 among them | Nothing |
| 3 | Browses tables of real-world data (dates, decimals, JSON, UUIDs, NULLs) and sees correct values | Per-engine decoding with the type fallback and unsupported-type conformance cases ([ADR 0014](docs/decisions/0014-lossless-values-and-dialects.md)). A value corpus on every engine, MariaDB too: dates and times at their extremes and in other zones, decimals, JSON, UUIDs, Unicode and binary values, read back through a table tab, Export All and an editor run, and exported as CSV and SQL INSERT and loaded back into an empty copy | Nothing |
| 4 | Runs typical queries against tables of a million rows or more without running out of memory or freezing | The 10,000-row editor limit with Export All, and driver tests over 2,000,000 rows. Pages seek past the edge row's key, or walk PostgreSQL heap block windows for a table with no key; OFFSET only under a user sort, a restored deep offset or a partitioned keyless table. Docker tests page 60k and 25k-row tables both ways and check the plan. A 1,000,000-row table is paged to its end and exported on PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse, Cassandra, ScyllaDB, SQLite and DuckDB, with bounds on time and on resident peak growth. The file engines' cases run in the unit suite, each in a test binary of its own, so the peak is its alone | Nothing |
| 5 | Edits data in place, and the changes commit correctly even when the connection or the app misbehaves | Write, row guard and commit resolution conformance on every engine, with the fault fakes and the grid save Docker test. `kill_during_save` kills TablePro halfway through a SQLite save: the file keeps none of it, and the next launch restores the session with its history, settings and saved tabs. A save into a SQLite file another program holds locked fails as `Busy(FileLocked)`, which says another program or an editor tab holds the file's lock, and leaves the file as it was whether the lock shows at `BEGIN IMMEDIATE` or at the `COMMIT` | Nothing |
| 6 | Trusts the app with credentials: TLS, SSH tunnels, no password in plain text | Verify full by default, the TLS conformance suite, the Secret Service, and statement logging silenced | An outside security review |
| 7 | Recovers when the network drops or the database restarts | Health monitoring, backoff and replay rules with their tests, a stopped container in the liveness tests, and a session test that restarts PostgreSQL: the read in flight runs again, the save in flight does not and leaves no row | Nothing |
| 8 | Works with a screen reader, the keyboard alone and larger text | Label audits of the picker, the connect pages, the workspace, the connect dialog and preferences, labelled cells and real-key tests. Sorting from the cell menu, named filter fields and cell editors, focus handed on when a control hides, and announced query results and errors. Columns resize from the keyboard, and a column sized by a key or a header drag draws at that width, also when it comes back. The ER diagram's tables are focusable list items that name their columns and joins | The manual pass in the backlog |
| 9 | Sees no message that cannot be translated, even while only English ships | Every string the app writes is in the template. Core errors carry values the app words itself: CSV import, cell and JSON parsing, type and default syntax, the keyring, certificate files, unsupported features, the SSH host, username and jump host checks, a failed write of the saved connections, the SSH runtime directory checks, ssh's exit status, and an ssh that would not start. A panic, an export encoder failure, an SSH failure with no sentence of its own and a TLS failure the app does not classify show the app's words and log the detail | Nothing |
| 10 | Uses the app daily for a week without an unrecoverable failure | Nothing yet | A dated week of daily use |
| 11 | Works with a database of many schemas or tables, such as one schema per tenant, without the sidebar or completion freezing | The large-catalog case on PostgreSQL with 100 schemas of 500 tables and MySQL with one database of 50,000: the sidebar's first listing, its search a key at a time, and completion after `FROM `, a key typed into it and after a schema's dot each have a time bound, none may stall the main loop past 100 ms, and the catalog has a bound on resident peak growth ([testing.md](docs/testing.md#large-catalog-case)) | Nothing |

## Out of scope

| Item | Reason |
|---|---|
| Plugins loaded at runtime | Drivers are linked in at compile time ([ADR 0001](docs/decisions/0001-no-plugin-system.md)) |
| Windows and macOS builds | Those platforms have their own apps in this repository |
| Embedded scripting (JavaScript, Python, Lua) | SQL is enough, and a scripting engine widens the attack surface |
| Hot-reloading drivers | Drivers are compiled in |
| Cloud sync of connections through a TablePro service | Not without a business model that needs it |
| KDE-native styling | The app runs with the Adwaita style everywhere |

The distribution channels, and why there is no AppImage or Snap, are in [ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md).
