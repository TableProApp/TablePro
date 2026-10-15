# Roadmap

**Status, 2026-10-15**: every capability in the tables below is in the tree. Nothing has shipped yet: no `linux-v*` tag has been cut. The [release criteria](#release-criteria) say what has to hold first, and the [backlog](#backlog) lists what is not built.

The app runs on GNOME 50 ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)) and connects to five engines, each a crate linked in at compile time ([ADR 0001](docs/decisions/0001-no-plugin-system.md)): [PostgreSQL](docs/drivers/postgresql.md), [MySQL and MariaDB](docs/drivers/mysql.md), [SQL Server](docs/drivers/sql-server.md), [ClickHouse](docs/drivers/clickhouse.md) and [SQLite](docs/drivers/sqlite.md).

## Implemented

### Connections

| Capability | Detail |
|---|---|
| Saved connections | Create, edit and rename, duplicate with the secrets carried to the copy, delete with or without the connection's history |
| Groups and colour tags | From the connection row's menu; each group is a section of the connection list |
| Import and export | A JSON file with no secrets in it, matched by id on the way back in |
| Test before saving | Test connects once and reports, then disconnects |
| Passwords | Kept in the Secret Service; a prompt asks when one is missing or refused, with Remember Password |
| Read-only connections | SQLite and ClickHouse refuse writes at the engine, PostgreSQL and MySQL run in read-only transactions, and SQL Server relies on the login with the app refusing saves; the switch's subtitle says which |
| SQLite files | Choose a file, create a new one, open one from Files, find a moved one with Locate, and choose read-only or read-write for one on a network filesystem |
| Kerberos for SQL Server | From the ticket cache, in the Flatpak through the KCM socket |
| Health and reconnect | A banner while the connection is lost, reconnect with backoff, and reads replayed after it; writes are never replayed |
| Cancel on the server | Stopping a query stops the statement on the server, on every engine |

### SSH

| Capability | Detail |
|---|---|
| System OpenSSH client | One ControlMaster per connection ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)); empty fields come from `~/.ssh/config` |
| Jump hosts | A ProxyJump chain, passed to `ssh -J` |
| Authentication | Agent, private key, password and keyboard-interactive; prompts go through the app's askpass helper |
| Host keys | An unknown or changed key is shown with its SHA256 fingerprint before connecting; a changed key can be replaced, a revoked one is refused |

### TLS

| Capability | Detail |
|---|---|
| Modes | Disable, Require and Verify full; Verify full is the default for a new connection |
| Certificates | CA file, client certificate and key (every network engine but SQL Server), and a server name override (MySQL only through an SSH tunnel) |
| Remedies | A TLS failure says what went wrong. An unknown issuer jumps to the CA file, and a name mismatch to the server name |

### Browse and edit

| Capability | Detail |
|---|---|
| Data grid | A virtualized `GtkColumnView` with keyboard-focusable cells, pages of a chosen size, and a pager with an exact or estimated row count and Count Rows |
| Filters | Per-column operators, a raw WHERE fragment checked as one expression, match any or all, kept per table |
| Sorting | A header click sorts tables on the server and query results in the grid |
| Cell editing | Editors by column kind: inline text, a multi-line editor, a calendar for dates, a toggle for booleans, JSON checked before saving; values are edited from their exact text, never from what the cell displays |
| Rows | Insert, duplicate and delete; Set NULL and Empty, and DEFAULT on a new row; undo and redo; save or discard pending changes, and stop a save |
| Bulk delete | Deleting 10 rows or more asks first |
| Copy | Copy, and Copy As rows, with headers, JSON, CSV, Markdown, IN clause or INSERT; Show Row as JSON |
| Column widths | Kept per table |
| CSV import | Into an existing table, with a column mapping, in one write batch |
| Sidebar | Tables, views, materialized views and foreign tables by schema, with search, Open in New Tab, Edit Structure, Show CREATE TABLE, Import CSV and Drop Table |

### Structure

| Capability | Detail |
|---|---|
| Table definition | Columns, indexes, foreign keys and column comments |
| Changes | Create, rename and drop tables; add, drop and rename columns, and change their type, nullability, default, comment, primary key and auto-increment; add and drop indexes and foreign keys |
| Review | The SQL is previewed, and a save that loses data or can stop halfway is reviewed before it runs |
| SQLite rebuilds | Changes SQLite cannot ALTER rebuild the table and keep its rows and indexes |

### SQL editor

| Capability | Detail |
|---|---|
| Editing | GtkSourceView with SQL highlighting, a scheme that follows the light or dark style, and toggle comment |
| Completion | Tables, views, columns, schemas, functions and keywords, with aliases resolved |
| Formatter | Format SQL, leaving a statement as typed when formatting would change its tokens |
| Scripts | Split per dialect (`DELIMITER`, `GO`, routine and trigger bodies), one result per statement, Run Selection and run the statement at the cursor |
| Find and replace | Ctrl+F and Ctrl+H, with case, whole word and regular expressions |
| Files | Open a .sql file into the editor, or drop one on it |
| Results | Several result sets per run, a banner at the 10,000-row limit with Export All, and Go to Error |
| Drafts | The editor's text is kept per connection |

### History and saved queries

| Capability | Detail |
|---|---|
| Query history | A SQLite database with full-text search, filters by connection, time and status, pins, export as SQL or CSV, and a retention period |
| What is recorded | Editor runs, and the SQL the app runs for grid saves, structure saves and imports; a run that sets a password is not recorded, and recording can be turned off |
| Show in Files | For the history database, from the history dialog and Preferences |
| Saved queries | Saved from the editor against a connection, listed by connection with the active one first, and opened in a new tab or the current one |

### Export

| Capability | Detail |
|---|---|
| Formats | CSV with its options, JSON, Markdown, HTML, XML, Excel, and SQL INSERT from a table tab |
| Scope | From a table tab, the current page or every row under its filter and sort. From the editor, the rows shown or every row, with the statement run again |
| Running | Off the GTK thread with progress and Stop; closing or quitting asks about a running export |

### Windows and sessions

| Capability | Detail |
|---|---|
| Window per session | A window holds one connection; another connection opens in a window of its own, and one already open brings its window forward ([ADR 0012](docs/decisions/0012-window-per-session.md)) |
| One instance | A second launch presents the running app; New Window (Ctrl+Shift+N) opens a picker |
| Tabs | `AdwTabView` with the tab overview and split header bars, adapting down to 360×294 |
| Session restore | The windows open at quit open again at launch, behind a preference |
| Closing safely | Unsaved edits, a save in flight or a running export ask before a window closes or the app quits; logout waits while edits are unsaved, a save runs or an export writes |
| Notifications | Work that finishes in a tab you are not looking at sends a notification |
| Preferences | Restore session, page size, query history, editor font and scheme, query timeout. A Confirm Before Deleting Rows switch is shown but nothing reads it yet (see the backlog) |
| Shortcuts and About | A shortcuts dialog, and About from the metainfo with third-party licenses and debug info |

### Packaging and platform

| Capability | Detail |
|---|---|
| Flatpak | The Devel manifest builds on GNOME 51 with every Meson suite in the sandbox, and is linted on every pull request |
| .deb and .rpm | Ubuntu 26.04 and 26.10 and Fedora 44, built offline in CI the way Launchpad and COPR build them, linted, then installed and started in fresh containers; a `linux-v*` tag uploads to the PPA and starts the COPR build ([ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md)) |
| Desktop integration | Desktop file with Open With for SQLite files, D-Bus activation, a man page, metainfo with screenshots, and SVG icons |
| Translations | Every user-facing string goes through gettext; CI checks `POTFILES.in` and the template |
| Logs | stderr, which the session journals, with JSON lines on request |
| Tests | Unit, GTK and accessibility suites, the conformance suites on every engine, and Docker suites for PostgreSQL with PgBouncer, MySQL with MariaDB, SQL Server, ClickHouse, SSH and the session ([testing.md](docs/testing.md)); every critical audit finding has named guards ([regression-tests.md](docs/regression-tests.md)) |

## Backlog

Not built yet, in no order.

### Connections

- A statement timeout per connection. Today one preference covers editor runs. Other calls have fixed limits: 15 seconds for metadata, 60 for a page or a count, 120 for a row save, and none for a schema change or an export.
- Kerberos against a service outside the client's realm, which needs an SPN override in tiberius.

### Browse, edit and structure

- Paste rows from the clipboard. Ctrl+V in the grid says it is not supported yet.
- Set a cell to `NOW()` or `CURRENT_TIMESTAMP`, which needs SQL expressions as cell values.
- Edit binary columns from and to a file. They are read-only today.
- Time and timestamp pickers. Dates have a calendar; times are typed.
- Save the column order per table.
- Make the Confirm Before Deleting Rows preference take effect. The switch is stored, but deleting rows does not read it.
- Functions, procedures, sequences and triggers in the sidebar.
- The CREATE INDEX statement for one index. Show CREATE TABLE lists them after the table on PostgreSQL, SQL Server and SQLite.
- Jump from a foreign key to the table it references.
- Reorder columns in the structure tab by dragging, with the ALTER previewed.
- An ER diagram.

### SQL editor

- Multi-cursor editing.
- Vim mode.
- Snippets.

### Release and project

- Before the first tag, the release setup [ADR 0018](docs/decisions/0018-ppa-copr-and-flathub-later.md#consequences) lists: the PPA, the COPR project, and the `linux-release` environment with what `release-linux.yml` names in its header.
- Write the Flathub manifest and the exception request by hand, and submit them.
- Put the PPA and COPR install commands in the README once both exist.
- An AUR PKGBUILD, kept by the community.
- The first translations in `po/LINGUAS`.
- A manual pass with Orca, the keyboard alone, High Contrast, 1.5x text scaling and a right-to-left locale.
- Install and use it on Ubuntu 26.04 and Fedora 44 by hand, and under KDE Plasma with the Adwaita style.
- A crash report a user can send. A panic goes to the journal today, and About offers the debug info and the issue tracker.
- A Linux user guide on docs.tablepro.app, a page on the marketing site, and a support channel.

### More engines

Each one is a crate under `crates/drivers` ([adding-drivers.md](docs/adding-drivers.md)), on a client library that meets the [supply-chain policy](docs/decisions/0005-supply-chain-policy.md).

| Engine | Client | Condition |
|---|---|---|
| Redis | redis 1.x (redis-rs) | None. fred, named here before, has had no release since 2025-02-27 |
| MongoDB | mongodb 3.x, default features off, `rustls-tls-aws-lc` | It must use the system trust store first: it fills its roots from webpki-roots unless `ca_file_path` is set, so it needs native roots upstream or `ca_file_path` set to the platform bundle |
| DuckDB | duckdb, from the DuckDB project | None |
| Cassandra and ScyllaDB | scylla 1.x with `rustls-023` | None |
| Oracle | none | Blocked. The oracle crate has one maintainer, no release since 2025-01-02, and needs the proprietary Oracle client |

Microsoft's mssql-tds is checked again each release as a SQL Server client. Today its TLS on Linux goes through OpenSSL and it takes no outside pull requests, so tiberius stays.

### Ideas

Not committed: server monitoring (sessions, locks, slow queries), maintenance commands, backup and restore, replication status, comparing result sets, schema diff and data sync between connections, scheduled queries, and opt-in usage telemetry.

## Release criteria

From the [production-readiness audit](docs/production-audit.md#what-production-ready-means-here), for GNOME 50. A user on Ubuntu 26.04 or Fedora 44:

1. Installs `tablepro` from the PPA or the COPR project, and gets updates from the system's updater.
2. Connects to their everyday PostgreSQL, MySQL, MariaDB, SQL Server, ClickHouse or SQLite database.
3. Browses tables of real-world data (dates, decimals, JSON, UUIDs, NULLs) and sees correct values.
4. Runs typical queries against tables of a million rows or more without running out of memory or freezing.
5. Edits data in place, and the changes commit correctly even when the connection or the app misbehaves.
6. Trusts the app with credentials: TLS, SSH tunnels, no password in plain text.
7. Recovers when the network drops or the database restarts.
8. Works with a screen reader, the keyboard alone and larger text.
9. Sees no message that cannot be translated, even while only English ships.
10. Uses the app daily for a week without an unrecoverable failure.

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
