# Changelog

All notable changes to TablePro will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Restore all open connections and tabs after quitting the app (#703)

### Fixed

- Auto-selection of first item fails with fast input in Database Switcher (#714)

## [0.31.2] - 2026-04-13

### Fixed

- Query tabs always named "Query 1" instead of incrementing (#695)
- Sidebar empty in new or restored window tabs (#694)
- Tab titles, order, and persistence lost on quit/restore
- PostgreSQL version display for v10+ (#698)
- License activation metadata and deactivation error handling

## [0.31.1] - 2026-04-12

### Fixed

- iCloud Sync not working on TestFlight/App Store builds (CloudKit environment set to Production)

## [0.31.0] - 2026-04-12

### Added

- Server Dashboard: active sessions, metrics, slow queries (PostgreSQL, MySQL, MSSQL, ClickHouse, DuckDB, SQLite)
- Handoff support between iOS and macOS
- iOS: full-text search in data browser, state restoration, iPad keyboard shortcuts

### Changed

- Sidebar table loading refactored: single source of truth, explicit loading states, no race conditions on database switch

### Fixed

- Create Database dialog now shows correct options per database type (encoding/LC_COLLATE for PostgreSQL, hidden for Redis/etcd)
- SSH tunnel with `~/.ssh/config` profiles (#672): `Include` directives, token expansion, multi-word `Host` filtering

## [0.30.1] - 2026-04-10

### Added

- Auto-uppercase SQL keywords setting (#660)
- Unified cell editor chevrons for boolean, enum, date, JSON, blob columns (#665)

### Fixed

- MSSQL connection failing on Docker/fresh SQL Server (#661)
- Context menu Format SQL not working (#659)

## [0.30.0] - 2026-04-10

### Added

- ER diagram with interactive layout, crow's foot notation, and PNG export (#186)
- Space key toggles FK preview popover (#648)
- Connection drag-to-reorder in iOS app with iCloud sync (#652)

### Fixed

- Fix export dialog doing nothing on macOS Tahoe due to incorrect window reference for save panel (#654)
- Fix column visibility popover and hex editor alignment — left-align per macOS HIG (#653)
- Accept SQLAlchemy-style connection URLs with driver hints (#642)

## [0.29.0] - 2026-04-09

### Added

- Maintenance tools via table context menu (VACUUM, ANALYZE, OPTIMIZE, REINDEX, CHECK TABLE, etc.)
- EXPLAIN plan visualization with diagram, tree, and raw views (PostgreSQL, MySQL)

### Fixed

- Fix cross-schema foreign key preview, edit, and navigation for PostgreSQL and MySQL (#644)
- Fix macOS HIG compliance: system colors, accessibility labels, theme tokens, localization
- Fix idle ping spin loop caused by exhausted AsyncStream iterator (#618)
- Skip exact row count for large tables — use database statistics estimate (#519)

### Changed

- Theme font pickers now list installed monospaced fonts dynamically instead of a fixed built-in list

## [0.28.0] - 2026-04-07

### Added

- Smart value detection for UUIDs in BINARY(16) and timestamps in integer columns
- Per-column "Display As" override via column header context menu
- iOS: safe mode, FK navigation, syntax highlighting

### Fixed

- Fix excessive idle ping traffic from orphaned monitor tasks
- Fix Cmd+W save not persisting data grid changes
- Fix window sizing, selection highlight, and connection switcher errors
- Move file loading off main thread, replace timing hacks with signals

## [0.27.5] - 2026-04-06

### Added

- iOS: groups, tags, filter, sort, pagination, query history, export to clipboard, Spotlight, Siri Shortcuts, Home Screen widget

### Fixed

- Fix crashes in SSH tunnel, export dialog, and jump host removal
- Fix data races in storage layers (MainActor isolation)
- Use native sheet presentation for all dialogs and file pickers
- Replace event monitors and timing hacks with native SwiftUI APIs

### Changed

- Migrate undo system to NSUndoManager

## [0.27.4] - 2026-04-05

### Added

- Cloudflare D1: batch query execution via REST API for multi-statement SQL
- Cloudflare D1: schema editing — CREATE TABLE, ADD/DROP COLUMN, CREATE/DROP INDEX

### Fixed

- Multi-statement SQL execution fails on Cloudflare D1, ClickHouse, and other drivers that don't support transactions

### Changed

- Use Apple-standard `xcodebuild archive` + `exportArchive` build pipeline with dSYM collection

## [0.27.3] - 2026-04-03

### Added

- Structure tab context menu with Copy Name, Copy Definition (SQL), Duplicate, and Delete for columns, indexes, and foreign keys
- Foreign key preview: press Cmd+Enter on a FK cell to see the referenced row in a popover
- Column header: sort ascending/descending and show all hidden columns in context menu
- Data grid: preview and navigate FK references from right-click context menu
- Data grid: add row from right-click on empty space

### Fixed

- Oracle: crash when opening views caused by OracleNIO state-machine corruption from concurrent queries, LONG column types, and DBMS_METADATA errors

## [0.27.2] - 2026-04-02

### Added

- Option to group all connection tabs in one window instead of separate windows per connection

### Changed

- Separate preferred themes for Light and Dark appearance modes, with automatic switching in Auto mode

## [0.27.1] - 2026-04-01

### Fixed

- Table queries incorrectly prefixed with connection username as schema name on non-schema databases (MySQL, MariaDB, ClickHouse, Redis, etc.), causing "Table 'username.table' doesn't exist" errors when opening a second table tab

## [0.27.0] - 2026-03-31

### Added

- Option to prompt for database password on every connection instead of saving to Keychain
- Autocompletion for filter fields: column names and SQL keywords suggested as you type (Raw SQL and Value fields)
- Multi-line support for Raw SQL filter field (Option+Enter for newline)
- Visual Create Table UI with multi-database support (sidebar → "Create New Table...")
- Auto-fit column width: double-click column divider or right-click → "Size to Fit"
- Collapsible results panel (`Cmd+Opt+R`), multiple result tabs for multi-statement queries, result pinning
- Inline error banner for query errors
- JSON syntax highlighting and brace matching in Details sidebar and JSON editor popover
- Database-aware SQL functions in field menu (MySQL, PostgreSQL, SQLite, SQL Server, ClickHouse)

### Changed

- Replace GCD dispatch patterns with Swift structured concurrency
- Refactor Details sidebar into modular field editor architecture with extracted editor components

### Fixed

- PostgreSQL: Schema name lost after app restart, causing "relation does not exist" errors for non-public schemas
- Error dialog OK button not dismissing when a SwiftUI sheet is active, making the app unusable
- SQL Server: Unicode characters (Thai, CJK, etc.) in nvarchar/nchar/ntext columns displaying as question marks
- Globe+F (fn+F) fullscreen shortcut not working in SwiftUI lifecycle app

## [0.26.0] - 2026-03-29

### Added

- Global toggle to disable all AI features (Settings > AI)
- Drag to reorder columns in the Structure tab (MySQL/MariaDB)
- Nested hierarchical groups for connection list (up to 3 levels deep)
- Confirmation dialogs for deep link queries, connection imports, and pre-connect scripts
- JSON fields in Row Details sidebar now display in a scrollable monospaced text area
- Open, save, and save-as for SQL files with native macOS title bar integration (#475)
- BigQuery plugin support (Google BigQuery analytics via REST API)

### Changed

- Removed query history sync from iCloud Sync (connections, groups, settings, and SSH profiles still sync)

### Fixed

- SQL editor not auto-focused on new tab and cursor missing after tab switch
- Long lines not scrollable horizontally in the SQL editor
- Home and End keys not moving cursor in the SQL editor (#448)
- SSH profile lost after app restart when iCloud Sync enabled
- MariaDB JSON columns showing as hex dumps instead of JSON text
- MongoDB Atlas TLS certificate verification failure
- ENUM/SET dropdown chevron buttons not showing on first table open

## [0.25.0] - 2026-03-27

### Added

- Connection sharing: export/import connections as `.tablepro` files with import preview and duplicate detection (#466)
- Encrypted export with credentials, protected by AES-256-GCM passphrase (Pro)
- Linked Folders: watch a shared directory for `.tablepro` files (Pro)
- Environment variable references (`$VAR`, `${VAR}`) in connection fields (Pro)

## [0.24.2] - 2026-03-26

### Fixed

- XLSX export producing corrupted files that Excel cannot open (#464)
- Deep link cold launch missing toolbar and duplicate windows (#465)

### Added

- Enum/set picker support for PostgreSQL custom enums, ClickHouse Enum8/Enum16, and DuckDB ENUM types
- Boolean picker for MSSQL BIT columns and MySQL TINYINT(1) convention
- Correct type classification for ClickHouse Nullable()/LowCardinality() wrappers, MSSQL MONEY/IMAGE/DATETIME2, DuckDB unsigned integers, and parameterized MySQL integer types

## [0.24.1] - 2026-03-26

### Fixed

- Keyboard shortcut hints in welcome window footer overflowing and truncating when too many items are displayed

## [0.24.0] - 2026-03-26

### Added

- Multi-select connections in Welcome window (Cmd+Click, Shift+Click) with bulk delete (⌘⌫), Move to Group, and multi-connect
- Reorder connections within groups and reorder groups in Welcome window
- ClickHouse, MSSQL, Redis, XLSX Export, MQL Export, and SQL Import now ship as built-in plugins
- Large document safety caps for syntax highlighting (skip >5MB, throttle >50KB)
- Lazy-load full values for LONGTEXT/MEDIUMTEXT/CLOB columns in the detail pane sidebar

### Fixed

- SSH profile connections displaying incorrect host/username on the Welcome window home screen (#454)
- Saved connections disappearing after normal app quit (Cmd+Q) while persisting after force quit (#452)
- Crash when disconnecting an etcd connection while requests are in-flight
- Detail pane showing truncated values for LONGTEXT/MEDIUMTEXT/CLOB columns, preventing correct editing
- Redis hash/list/set/zset/stream views showing empty or misaligned rows when values contained binary, null, or integer types

## [0.23.2] - 2026-03-24

### Fixed

- MongoDB Atlas connections failing to authenticate (#438)
- MongoDB TLS certificate verification skipped for SRV connections
- Active tab data no longer refreshes when switching back to the app window
- Undo history preserved when switching between database tables
- Health monitor now detects stuck queries beyond the configured timeout
- SSH tunnel closure errors now logged instead of silently discarded
- Schema/database restore errors during reconnect now logged
- Memory not released after closing tabs
- New tabs opening as separate windows instead of joining the connection tab group
- Clicking tables in sidebar not opening table tabs

## [0.23.1] - 2026-03-24

### Added

- Test Connection button in SSH profile editor to validate SSH connectivity independently

### Changed

- Improve performance: faster sorting, lower memory usage, adaptive tab eviction

## [0.23.0] - 2026-03-22

### Added

- Redis key namespace tree view with collapse/expand grouping in sidebar (#418)
- Keyboard focus navigation (Tab, Ctrl+J/K/N/P, arrow keys) for connection list, quick switcher, and database switcher
- MongoDB `mongodb+srv://` URI support with SRV toggle, Auth Mechanism dropdown, and Replica Set field (#419)
- Show all available database types in connection form with install status badge (#418)

### Changed

- MongoDB `authSource` defaults to database name per MongoDB URI spec instead of always "admin"

### Fixed

- DuckDB: TIMESTAMPTZ, TIMETZ, and other temporal columns displaying as null (#424)
- Onboarding "Get Started" button not rendering on macOS 15 until window loses focus (#420)
- MongoDB collection loading uses `estimatedDocumentCount` and smaller schema sample for faster sidebar population

## [0.22.1] - 2026-03-22

### Added

- Show/hide row numbers column in data grid (Settings > Data Grid)
- Persist column widths and order per table across tab switches, view toggles, and app restarts

### Fixed

- Show correct version for installed registry plugins (#410)
- Dangling pointer in release builds due to incorrect withUnsafeBufferPointer usage
- AI provider connection test error handling (#407)
- Use-after-free crash in Redis plugin redisFree

## [0.22.0] - 2026-03-21

### Added

- Export query results directly to CSV, JSON, SQL, XLSX, or MQL via File menu, context menu, or toolbar
- Pro license gating for Safe Mode (Touch ID) and XLSX export
- License activation dialog

- Reusable SSH tunnel profiles: save SSH configurations once and select them across multiple connections
- Ctrl+HJKL navigation as arrow key alternative for keyboards without dedicated arrow keys
- Amazon DynamoDB database support with PartiQL queries, AWS IAM/Profile/SSO authentication, GSI/LSI browsing, table scanning, capacity display, and DynamoDB Local support

### Fixed

- High CPU usage (79%+) and energy consumption when idle (#394)
- etcd connection failing with 404 when gRPC gateway uses a different API prefix (auto-detects `/v3/`, `/v3beta/`, `/v3alpha/`)
- Data grid editing (delete rows, modify cells, add rows) not working in query tabs (#383)

## [0.21.0] - 2026-03-19

### Added

- Cloudflare D1 database support
- Match highlighting in autocomplete suggestions (matched characters shown in bold)
- Loading spinner in autocomplete popup while fetching column metadata

### Changed

- Refactored autocomplete popup to native SwiftUI (visible selection highlight, native accent color, scroll-to-selection)
- Autocomplete now suppresses noisy empty-prefix suggestions in non-browseable contexts (e.g., after SELECT, WHERE)
- Autocomplete ranking stays consistent as you type (unified fuzzy scoring between initial display and live filtering)
- Increased autocomplete suggestion limit from 20 to 40 for schema-heavy contexts (FROM, SELECT, WHERE)

## [0.20.4] - 2026-03-19

### Fixed

- SQL syntax error when editing columns with reserved keyword names (e.g., `database`, `table`, `order`) in MySQL/PostgreSQL/SQLite
- High CPU usage and memory leaks at idle
- N+1 query performance in foreign key fetching with bulk queries
- Architecture-specific update delivery using `sparkle:hardwareRequirements`

### Changed

- Improved performance for medium and low severity bottlenecks (query history, tab persistence, sidebar rendering)

## [0.20.3] - 2026-03-18

### Added

- Optional iCloud Keychain sync for connection passwords

### Fixed

- `Use ~/.pgpass` setting not persisting when saving a PostgreSQL connection

## [0.20.2] - 2026-03-18

### Fixed

- Safe mode badge not displaying for silent level
- Safe mode level reading from immutable connection state instead of live toolbar state
- `~/.pgpass` password lookup using SSH tunnel host instead of original host when connecting through SSH

## [0.20.1] - 2026-03-17

### Fixed

- Plugin registry compatibility with PluginKit version 2

## [0.20.0] - 2026-03-17

### Added

- Turkish language in Settings > General (Türkçe) with Turkish translations for UI strings
- etcd v3 plugin with prefix-tree key browsing, etcdctl syntax editor, lease management, watch, mTLS, auth, and cluster info
- Save Changes button in toolbar for committing pending data edits
- Confirmation dialog before deleting a connection
- Confirmation dialog before sort, pagination, filter, or search discards unsaved edits

### Fixed

- SSH tunnel crashes caused by concurrent libssh2 calls on the same session
- Unsaved cell edits lost when switching tabs, sorting, paginating, filtering, or switching apps
- Auto-reconnect and health monitor silently discarding unsaved changes
- SSH tunnel recovery failing after tunnel death due to stale driver state
- Health monitor ping interfering with active user queries
- Connection test not cleaning up SSH tunnel on completion
- Test connection success indicator not resetting after field changes
- SSH port field accepting invalid values
- DROP TABLE and TRUNCATE TABLE sidebar operations producing no SQL for plugin-based drivers
- Foreign key navigation arrows not appearing after switching databases with Cmd+K on MySQL
- Sidebar not refreshing after creating or dropping tables
- Dropping a table disconnecting the database when the dropped table's tab was active

## [0.19.1] - 2026-03-16

### Fixed

- SSH tunnel connections timing out due to relay deadlock
- Plugin metadata dispatch failing for externally installed plugins
- SSH public key authentication error messages now include detailed failure reason

## [0.19.0] - 2026-03-15

### Added

- iCloud Sync (Pro): sync connections, groups, tags, settings, and query history across Macs with per-category toggles, conflict resolution, and real-time status indicator
- SQL Favorites: save frequently used queries with optional keyword bindings for autocomplete expansion
- Copy selected rows as JSON from context menu and Edit menu
- Help menu and welcome screen links to website, documentation, GitHub, and sponsor page
- Display BLOB data as hex dump in detail view sidebar

### Fixed

- SSH agent connections failing when socket path contains `~` (e.g., 1Password agent)
- Keychain authorization prompt no longer appears on every table open

## [0.18.1] - 2026-03-14

### Fixed

- Plugin download counts now accumulate across all versions instead of only counting the current release

## [0.18.0] - 2026-03-14

### Added

- Theme engine: 4 built-in themes (Default Light/Dark, Dracula, Nord), custom themes with full color/font/layout customization, import/export as JSON
- Theme registry: browse, install, and update community themes from the plugin registry
- App-level appearance mode: Light, Dark, or Auto (follow system), independent of theme
- Cassandra and ScyllaDB database support (downloadable plugin)
- SSH TOTP/two-factor authentication with auto-generate and prompt modes
- SSH host key verification with fingerprint confirmation
- Keyboard Interactive SSH authentication
- Column visibility: toggle columns on/off via status bar or header context menu
- Copy as INSERT/UPDATE SQL from data grid context menu
- `~/.pgpass` support for PostgreSQL/Redshift connections
- Pre-connect script: run a shell command before each connection
- MSSQL query cancellation and lock timeout support
- Custom plugin registry URL for enterprise/private registries

### Changed

- Extracted MSSQL, MongoDB, Redis, XLSX export, MQL export, and SQL import into downloadable plugins. MySQL, PostgreSQL, SQLite, CSV, JSON, and SQL export remain built-in
- Redesigned Plugins settings with master-detail layout and download counts
- All database-specific behavior now driven by plugin metadata instead of hardcoded switches, enabling third-party database plugins
- Connection form fields, sidebar labels, and SQL dialect features are now fully plugin-driven

### Fixed

- Plugin icon rendering now supports custom asset images alongside SF Symbols

## [0.17.0] - 2026-03-11

### Added

- DuckDB database support — connect to `.duckdb` files, query CSV/Parquet/JSON files via SQL, schema navigation, and DuckDB extension management
- MongoDB configurable auth database (`authSource`) — authenticate against any database instead of hardcoded `admin`

### Fixed

- MongoDB Read Preference, Write Concern, and Redis Database not persisted across app restarts

- Result truncation at 100K rows now reported to UI via `PluginQueryResult.isTruncated` instead of being silently discarded
- DELETE and UPDATE queries using all columns in WHERE clause instead of just the primary key for PostgreSQL, Redshift, MSSQL, and ClickHouse
- SSL/TLS always being enabled for MongoDB, Redis, and ClickHouse connections due to case mismatch in SSL mode string comparison (#249)
- Redis sidebar click showing data briefly then going empty due to double-navigation race condition (#251)
- MongoDB showing "Invalid database name: ''" when connecting without a database name

### Changed

- Namespaced `disabledPlugins` UserDefaults key to `com.TablePro.disabledPlugins` with automatic migration
- Removed unused plugin capability types (sqlDialect, aiProvider, cellRenderer, sidebarPanel)
- SQLite driver extracted from built-in bundle to downloadable plugin, reducing app size
- Unified error formatting across all database drivers via default `PluginDriverError.errorDescription`, removing 10 per-driver implementations
- Standardized async bridging: 5 queue-based drivers (MySQL, PostgreSQL, MongoDB, Redis, MSSQL) now use shared `pluginDispatchAsync` helper
- Added localization to remaining driver error messages (MySQL, PostgreSQL, ClickHouse, Oracle, Redis, MongoDB)
- NoSQL query building moved from Core to MongoDB/Redis plugins via optional `PluginDatabaseDriver` protocol methods
- Standardized parameter binding across all database drivers with improved default escaping (type-aware numeric handling, NUL byte stripping, NULL literal support)

### Added

- Open SQLite database files directly from Finder by double-clicking `.sqlite`, `.sqlite3`, `.db3`, `.s3db`, `.sl3`, and `.sqlitedb` files (#262)
- Export plugin options (CSV, XLSX, JSON, SQL, MQL) now persist across app restarts
- Plugins can declare settings views rendered in Settings > Plugins
- True prepared statements for MSSQL (`sp_executesql`) and ClickHouse (HTTP query parameters), eliminating string interpolation for parameterized queries
- Batch query operations for MSSQL, Oracle, and ClickHouse, eliminating N+1 query patterns for column, foreign key, and database metadata fetching; SQLite adds a batched `fetchAllForeignKeys` override within PRAGMA limitations
- `PluginDriverError` protocol in TableProPluginKit for structured error reporting from driver plugins, with richer connection error messages showing error codes and SQL states
- `pluginDispatchAsync` concurrency helper in TableProPluginKit for standardized async bridging in plugins
- Shared `PluginRowLimits` constant in TableProPluginKit with 100K row default, enforced across all 8 driver plugins (ClickHouse, MSSQL, Oracle previously had no cap)
- `driverVariant(for:)` method on `DriverPlugin` protocol for dynamic multi-type plugin dispatch, replacing hardcoded variant mapping
- Safe mode levels: per-connection setting with 6 levels (Silent, Alert, Alert Full, Safe Mode, Safe Mode Full, Read-Only) replacing the boolean read-only toggle, with confirmation dialogs and Touch ID/password authentication for stricter levels
- Preview tabs: single-click opens a temporary preview tab, double-click or editing promotes it to a permanent tab
- Import plugin system: SQL import extracted into a `.tableplugin` bundle, matching the export plugin architecture
- `ImportFormatPlugin` protocol in TableProPluginKit for building custom import format plugins
- SQLImportPlugin as the first import format plugin (SQL files and .gz compressed SQL)
- Oracle and ClickHouse shipped as downloadable plugins, reducing app bundle size for most users
- Plugin install prompt when connecting to a database whose driver plugin is not installed
- `databaseTypeIds` field on registry plugins for mapping registry entries to database types
- `build-plugin.sh` script and `build-plugin.yml` CI workflow for building standalone plugin releases

## [0.16.1] - 2026-03-09

### Fixed

- Stale filter causing repeated errors when restoring tabs after schema/database switch (#237)
- Sidebar showing old tables during database/schema switch instead of loading state
- Sidebar search field disappearing when no tables match filter on macOS 15 and earlier (#235)
- Disabled plugin database types still appearing in connection form picker
- Main window not closing before reopening welcome screen on connection failure

## [0.16.0] - 2026-03-09

### Fixed

- Inspector separator no longer bleeds into toolbar area with default connection color (#228)
- Inspector toggle no longer lags due to synchronous UserDefaults writes during animation (#229)

### Added

- Direct `.tableplugin` bundle installation via file picker, Finder double-click, and drag-and-drop
- Plugin capability enforcement — registration now gated on declared capabilities, with validation warnings for mismatches
- Plugin dependency declarations — plugins can declare required dependencies via `TableProPlugin.dependencies`, validated at load time
- Plugin state change notification (`pluginStateDidChange`) posted when plugins are enabled/disabled
- Restart recommendation banner in Settings > Plugins after uninstalling a plugin
- Startup commands — run custom SQL after connecting (e.g., SET time_zone) in Connection > Advanced tab
- Plugin system architecture — all 8 database drivers (MySQL, PostgreSQL, SQLite, ClickHouse, MSSQL, MongoDB, Redis, Oracle) extracted into `.tableplugin` bundles loaded at runtime
- Export format plugins — all 5 export formats (CSV, JSON, SQL, XLSX, MQL) extracted into `.tableplugin` bundles with plugin-provided option views and per-table option columns
- Settings > Plugins tab for plugin management — list installed plugins, enable/disable, install from file, uninstall user plugins, view plugin details
- Plugin marketplace — browse, search, and install plugins from the GitHub-hosted registry with SHA-256 checksum verification, ETag caching, and offline fallback
- TableProPluginKit framework — shared protocols and types for driver and export plugins
- ClickHouse database support with query progress tracking, EXPLAIN variants, TLS/HTTPS, server-side cancellation, and Parts view

### Changed

- Reduce memory: eliminate dedicated ping driver (~30-50 MB per connection), use main driver for health checks
- Reduce memory: evict inactive native window-tab row data after 5s, re-fetch on focus
- Reduce memory: lazy-load plugin bundles on first use instead of at startup (~20-30 MB saved)
- Reduce memory: remove duplicate sourceQuery string from RowBuffer
- Reduce memory: InMemoryRowProvider references RowBuffer directly instead of copying rows (~3-10 MB per tab)
- Reduce memory: eliminate metadata driver entirely, multiplex all queries on main driver (~30-50 MB per connection)
- Reduce memory: lazy AIChatViewModel initialization (deferred until AI panel is first opened)
- Reduce memory: remove duplicate connections array from ContentView (use ConnectionStorage.shared directly)
- Reduce CPU: consolidate per-editor NSEvent monitors into shared EditorEventRouter singleton (O(n) → O(1) per event)
- Fix tab persistence: aggregate tabs from all windows at quit time instead of last-write-wins per-coordinator save
- Split DatabaseManager.sessionVersion into fine-grained connectionListVersion and connectionStatusVersion to reduce cascade re-renders
- Extract AppState property reads into local lets in view bodies for explicit granular observation tracking
- Reorganized project directory structure: Services, Utilities, Models split into domain-specific subdirectories
- Database driver code moved from monolithic app binary into independent plugin bundles under `Plugins/`

## [0.15.0] - 2026-03-08

### Added

- Oracle Database support via OCI (Oracle Call Interface)
- Add database URL scheme support — open connections directly from terminal with `open "mysql://user@host/db" -a TablePro` (supports MySQL, PostgreSQL, SQLite, MongoDB, Redis, MSSQL, Oracle)
- SSH Agent authentication method for SSH tunnels (compatible with 1Password SSH Agent, Secretive, ssh-agent)
- Multi-jump SSH support — chain multiple SSH hops (ProxyJump) to reach databases through bastion hosts

### Changed

- Replace CodeEditLanguages xcframework (38 grammars) with local package compiling only SQL, Bash, and JavaScript, reducing app binary size by ~55%

### Fixed

- Fix memory leak where session state objects were recreated on every tab open due to SwiftUI `@State` init trap, causing 785MB usage at 5 tabs with 734MB retained after closing
- Fix per-cell field editor allocation in DataGrid creating 180+ NSTextView instances instead of sharing one
- Fix NSEvent monitor not removed on all popover dismissal paths in connection switcher
- Fix race condition in FreeTDS `disconnect()` where `dbproc` was set to nil without holding the lock
- Fix data race in `MainContentCoordinator.deinit` reading `nonisolated(unsafe)` flags from arbitrary threads
- Fix JSON encoding and file I/O blocking the main thread in TabStateStorage
- Fix MySQL/MariaDB getting `BEGIN` instead of `START TRANSACTION` in table operations and SQL preview
- Fix port resetting to default value when editing a connection with a custom port
- Replace `.onTapGesture` with `Button` in color pickers, section headers, group headers, and connection switcher for VoiceOver accessibility
- Fix data race on `isAppTerminating` static var in `MainContentCoordinator` using `OSAllocatedUnfairLock`
- Fix `MainActor.assumeIsolated` crash risk in `VimKeyInterceptor` notification observer
- Fix data race on `conn` pointer in `LibPQConnection` during disconnect and cancel
- Fix SSH askpass script written with world-readable permissions; now uses atomic `0o700` creation and immediate cleanup
- Fix potential dict mutation during iteration in `DatabaseManager.disconnectAll()`
- Fix welcome screen showing blank panel when connections have orphaned group IDs
- Fix multiple tabs auto-executing queries simultaneously on connection restore, causing lag
- Fix welcome window becoming oversized after closing main windows due to AppKit scene restoration
- Fix unescaped identifiers in MySQL `SHOW CREATE TABLE`/`VIEW` queries allowing SQL injection via table names
- Fix `QueryResultRow` equality ignoring cell values, preventing SwiftUI from re-rendering updated rows
- Fix status bar row info text rendering off-center due to duplicate spacer
- Fix `Cmd+Delete` in sidebar search or right sidebar clearing the query editor
- Fix SSH tunnel processes not terminated when closing connection window or quitting the app

## [0.14.1] - 2026-03-06

### Added

- Add database and schema switching for PostgreSQL connections via ⌘K

## [0.14.0] - 2026-03-05

### Added

- Microsoft SQL Server (MSSQL) database support via FreeTDS
- Support for editing and deleting rows in tables without a primary key

### Fixed

- Fix MSSQL connection losing selected database after disconnect and reconnect when no default database is configured
- DELETE operations on tables without a primary key now show an error if row data is missing instead of being silently dropped
- SQLite and MSSQL now use safe single-row limits for DELETE and UPDATE on tables without a primary key
- Fix high CPU/RAM on app launch from blocking storage init, unsynchronized health monitors, and excessive retry loops
- Fix O(n log n) row cache eviction in RowProvider by replacing sorted eviction with O(n) distance-threshold filter
- Fix O(n) string operations in GeometryWKBParser, RedisDriver, and autocomplete scoring by switching to NSString O(1) indexing
- Fix slow database switcher loading by replacing N+1 metadata queries with single batched queries (MySQL, PostgreSQL, Redshift)
- Fix slow Redis key browsing by pipelining TYPE and TTL commands in a single round trip instead of 3 sequential commands per key
- Fix slow SQL export startup by batching COUNT(*) queries via UNION ALL and batching dependent sequence/type lookups
- Fix slow AI Chat schema loading by fetching all foreign keys in a single bulk query instead of per-table

## [0.13.0] - 2026-03-04

### Added

- Redis database support with key-value browsing, database-level sidebar (db0–db15), TTL management, and interactive CLI
- TablePlus-compatible database URL handling: `open -a TablePro "postgresql://user@host/db"` with support for schema switching, table opening, filters, color, and environment tags

### Fixed

- Fix sidebar search field and main content area background colors to blend with macOS vibrancy
- Fix POINT and geometry columns showing blank values in MySQL and wrong type label in sidebar

## [0.12.0] - 2026-03-03

### Added

- Amazon Redshift database support
- Deep link support via `tablepro://` URL scheme for opening connections, tables, queries, and importing connections
- "Copy as URL" context menu action on connections to copy connection details as a URL string (e.g., `mysql://user:pass@host/db`)
- Auto-show inspector option: automatically open the right sidebar when selecting a row (Settings > Data Grid)
- ENUM and SET columns now open their picker on single click with a chevron indicator, matching boolean column behavior
- Homebrew Cask installation via `brew install --cask tablepro`

### Fixed

- "Table not found" error when switching databases within the same connection (Cmd+K) while a table tab is open
- Right sidebar state now persists across native window-tabs instead of resetting to closed

## [0.11.1] - 2026-03-02

### Fixed

- MySQL second tab showing empty rows due to premature coordinator teardown during native macOS tab group merging
- MongoDB tab name showing "MQL Query" instead of collection name when using bracket notation `db["collection"].find()`

## [0.11.0] - 2026-03-02

### Added

- Environment color indicator: subtle toolbar tint based on connection color for at-a-glance environment identification
- Import database connections from SSH tunnel URLs (e.g., `mysql+ssh://`, `postgresql+ssh://`)
- Connection groups for organizing database connections into folders with colored headers

### Fixed

- Toolbar briefly showing "MySQL" and missing version (e.g., "MongoDB" instead of "MongoDB 8.2.5") when opening a new tab
- Keyboard shortcuts not working (beep sound) after connecting from welcome screen until a second tab is opened
- Toolbar overflow menu showing only one item and missing all other buttons when window is narrow
- AI chat showing "SQL" language label and missing syntax highlighting for MongoDB code blocks

### Changed

- Refactored toolbar to use individual `ToolbarItem` entries with `Label` for native macOS overflow behavior, and moved History/Export/Import to `.secondaryAction` overflow menu
- Redesigned right sidebar detail pane with compact field layout and type-aware editors

## [0.10.0] - 2026-03-01

### Added

- Support for multiple independent database connections in separate windows with per-window session isolation
- MongoDB database support
- Custom About window with version info and links (Website, GitHub, Documentation)
- Import database connections from URL/connection string (e.g., `postgresql://user:pass@host:5432/db`)
- Release notes in Sparkle update window

### Fixed

- New row (Cmd+I) and duplicated row not appearing in datagrid until manual refresh
- PostgreSQL SSH tunnel connections failing with "no encryption" due to SSL config not being preserved
- PostgreSQL SSL `sslrootcert` passed unconditionally to libpq, causing certificate verification failure even in `Required` mode

## [0.9.2] - 2026-02-28

### Fixed

- Fix app bundle not ad-hoc signed — signing step was unreachable when no dylibs were bundled

## [0.9.1] - 2026-02-28

### Fixed

- Fix Sparkle auto-update failing with "improperly signed" error — release ZIPs now preserve framework symlinks and include proper ad-hoc code signatures

## [0.9.0] - 2026-02-28

### Added

- Vim keybindings for SQL editor (Normal/Insert/Visual modes, motions, operators, :w/:q commands) with toggle in Editor Settings
- `^` and `_` motions (first non-blank character) in Vim normal, visual, and operator-pending modes
- `:q` command to close current tab in Vim command-line mode
- PostgreSQL schema switching via ⌘K database switcher (browse and switch between schemas like `public`, `auth`, custom schemas)

### Changed

- Convert QueryHistoryStorage and QueryHistoryManager from callback-based async dispatch to native Swift async/await — eliminates double thread hops per history operation
- Consolidate ExportService @Published properties into single state struct — reduces objectWillChange events from 7 per batch to 1
- Consolidate ImportService @Published properties into single state struct — reduces objectWillChange events during SQL import
- Replace DispatchQueue.main.asyncAfter chains in AppDelegate startup with structured Task-based retry loops
- Merge 3 identical Combine notification subscriptions in SidebarViewModel into Publishers.Merge3
- Make AIChatStorage encoder/decoder static — shared across all instances instead of duplicated

### Fixed

- Cell edit showing modified background but displaying original value until save (reloadData during active editing ignored by NSTableView, updateNSView blocked by editedRow guard)
- Undo on inserted row cell edit not syncing insertedRowData (stale values after undo)
- Vim Escape key not exiting Insert/Visual mode when autocomplete popup is visible (popup's event monitor consumed the key)
- Copy (Cmd+C) and Cut (Cmd+X) not working in SQL editor — clipboard retained old value due to CodeEditTextView's copy: silently failing
- Vim yank/delete operations not syncing to system clipboard (register only stored text internally)
- Vim word motions (`w`, `b`, `e`) using two-class word boundary detection instead of correct three-class (word chars, punctuation, whitespace)
- Vim visual mode selection now correctly includes cursor character (inclusive selection matching real Vim behavior)
- Arrow keys now work in Vim visual/normal mode (mapped to h/j/k/l instead of bypassing the Vim engine)
- Vim block cursor now follows the moving end of the selection in visual mode instead of staying at the anchor
- Vim visual mode selection highlight now renders visibly (trigger needsDisplay after programmatic selection)
- Fix event monitor leaks in SQL editor — `deinit` now cleans up NSEvent monitors, notification observers, and work items that leaked when CodeEditSourceEditor never called `destroy()`
- Fix unbounded memory growth from NativeTabRegistry holding full QueryTab objects (including RowBuffer references) — registry now stores lightweight TabSnapshot structs
- Fix SortedRowsCache storing full row copies — now stores index permutations only, halving sorted-tab memory
- Fix schema provider memory leak — shared providers are now reference-counted with 5s grace period removal when all windows for a connection close
- Fix duplicate schema fetches in InlineSuggestionManager — now shares the coordinator's SQLSchemaProvider instead of maintaining a separate cache
- Fix background tabs retaining full result data indefinitely — RowBuffer eviction frees memory for inactive tabs (re-fetched on switch back)
- Fix InMemoryRowProvider bulk cache eviction — now uses proximity-based eviction keeping entries near current scroll position
- Fix stale tabRowProviders entries when tab IDs change without count changing
- Fix crash on macOS 14.x caused by `_strchrnul` symbol not found in libpq.5.dylib — switch libpq and OpenSSL from dynamic Homebrew linking to vendored static libraries built with MACOSX_DEPLOYMENT_TARGET=14.0
- Fix duplicate tabs and lag when inserting SQL from AI Chat or History panel with multiple window-tabs open — notification handlers now only fire in the key window
- Fix "Run in New Tab" race condition in History panel — replaced fragile two-notification + 100ms delay pattern with a single atomic notification
- Fix MainContentCoordinator deinit Task that may never execute — added explicit teardown() method with didTeardown guard and orphaned schema provider purge
- Fix SQLEditorCoordinator deinit deferring InlineSuggestionManager cleanup to Task — added explicit destroy() lifecycle and didDestroy guard with warning log
- Fix ExportService while-true batch loops not checking Task.isCancelled — cancelled exports now stop promptly instead of running all remaining batches
- Fix DataGridView full column reconfiguration on every resultVersion bump — narrowed rebuild condition to only trigger when transitioning from empty state
- Fix ConnectionHealthMonitor fixed 30s interval that delays failure detection — added checkNow() with wakeUpContinuation for immediate health checks and exponential backoff
- Fix HistoryPanelView and TableStructureView asyncAfter copy-reset timers not cancellable — replaced with cancellable Task pattern
- Fix MainContentView redundant onChange handler causing cascading re-renders on tab/table changes
- Fix DatabaseManager notification observer creating unnecessary Tasks when self is already deallocated — added guard let self before Task creation

## [0.8.0] - 2026-02-27

### Changed

- Refactored sidebar table list to MVVM architecture with testable SidebarViewModel
- Extracted TableRow and context menu into separate files (TableRowView.swift, SidebarContextMenu.swift)
- Migrated to native macOS window tabs (`NSWindow` tabbing) — tab bar is now rendered by macOS itself, identical to Finder/Safari/Xcode tabs with automatic dark/light mode support, drag-to-reorder, and "Merge All Windows" for free
- Each tab is a full independent window with its own sidebar, editor, and state — no more shared tab manager or ZStack keep-alive pattern
- New Tab (Cmd+T) creates a native macOS window tab; Close Tab (Cmd+W) closes the native tab
- Tab switching (Cmd+Shift+[/], Cmd+1-9) now uses native macOS tab navigation
- Sidebar table selection is per-window-tab (independent of other tabs)
- Tab persistence now saves/restores combined state from all native window tabs via NativeTabRegistry; restored tabs reopen as individual native window tabs
- Sidebar table click navigates in-place when no unsaved changes; opens new native tab when dirty
- FK navigation follows the same in-place/new-tab behavior based on unsaved changes
- "Show All Tables" now opens metadata query in a new native tab instead of appending to the current window
- Create Table success closes the create-table window and opens the new table in a fresh native tab
- Window title updates dynamically after navigate-in-place (sidebar click, FK navigation)

### Fixed

- Sidebar loses keyboard focus (arrow key navigation) after opening a second table tab
- Sidebar active state flash and loss when clicking a table that opens in a new native window tab — removed the async revert; each window now re-syncs its sidebar via `NSWindow.didBecomeKeyNotification`, and programmatic syncs skip navigation via an early-return guard
- Sidebar loses active state when opening a second table in a new native window tab — `handleTabSelectionChange` now calls `syncSidebarToCurrentTab()` so the new window's empty `localSelectedTables` is seeded from the restored tab
- Sidebar now refreshes immediately after switching databases via Cmd+K — clears `session.tables` during the switch so `SidebarView.onChange` triggers `loadTables()` against the new database without requiring a manual refresh
- Cmd+W in empty state (after all tabs are cleared) now closes the connection window and disconnects, instead of doing nothing
- Fix Cmd+K database switch flooding all windows with error alerts — `.refreshAll` broadcast caused every window to re-execute its table query against the wrong database; now only the current tab re-executes, and only if its table exists in the new database
- Fix clicking a table in the sidebar replacing the current tab instead of opening a new native tab
- Fix clicking a table from a query tab overwriting the SQL editor instead of opening a separate table tab
- Tab persistence no longer overwrites combined state from all windows when a single window saves — uses NativeTabRegistry for combined state
- Query text editing in one window no longer corrupts other windows' persisted tab state
- Fix Cmd+W on any tab disconnecting the session and showing welcome screen — now only disconnects when the last main window is closed
- Fix Cmd+T from empty state creating two native tabs instead of one — now adds a query tab to the current window
- Fix clicking a table in the sidebar from empty state not opening the table — now creates a table tab in the current window
- Fix native tab title showing "SQL Query" instead of the table name when opening a table from empty state
- Fix Cmd+W on the last tab disconnecting the session instead of returning to empty state

### Removed

- Removed broken SidebarFocusRestorer (non-functional NSViewRepresentable focus hack)
- Removed dead code: unused onTablePro callback, single-table toggle methods
- Custom AppKit tab bar (NativeTabBarView) — replaced by native macOS window tab bar
- Removed vestigial multi-tab code: `performDirectTabSwitch`, `skipNextTabChangeOnChange`, `tabPendingChanges`, `tabSelectionCache`, `lastFlushTime`, `filterStateSavedExternally`, `flushSelectionCache`, `duplicateTab`, `togglePin`, `selectTab`, `switchToDatabase` (legacy)

### Performance

- Cache SQLSchemaProvider per connection so new native tabs reuse the already-loaded schema instead of re-fetching tables and columns from the database (saves 500ms-2s per tab)
- Schema loading now runs in background, no longer blocks the data query from starting — table data appears immediately while autocomplete schema loads concurrently
- Remove unconditional 100ms sleep in `waitForConnectionAndExecute` when connection is already established
- Defer `loadTableMetadataIfNeeded` until after the tab's first query completes, avoiding a redundant DB round-trip during tab initialization
- Replace `@ObservedObject dbManager` in ContentView with targeted `@State` + `onReceive` — eliminates O(N) view cascade where every window re-rendered on any DatabaseManager state change
- Remove `@StateObject dbManager` from TableProApp — prevents app-level body re-evaluation on every DatabaseManager publish
- Batch `connectToSession` session mutations into a single `activeSessions` write — reduces 5 separate `objectWillChange` publishes to 1
- Remove redundant `DatabaseManager.updateSession` calls in tab change handlers — NativeTabRegistry already handles persistence, eliminating unnecessary `@Published` cascades
- Add initialization guard to `initializeAndRestoreTabs` preventing duplicate query execution from racing `.task` and `onChange(of: selectedTabId)` paths
- Replace `onChange(of: DatabaseManager.shared.currentSession?.*)` with per-window `onReceive` filtered by connection ID — stops SwiftUI from tracking the global DatabaseManager singleton as a dependency
- Guard health monitor status writes to skip no-op `.connected` → `.connected` transitions — eliminates idle 30-second cascade on all windows
- Extract all menu commands into `AppMenuCommands` struct — `AppState` changes now only re-evaluate menu items, not the Scene body / all WindowGroups
- Add `isContentViewEquivalent(to:)` comparison on `ConnectionSession` — skips `@State` writes when only `tabs`, `selectedTabId`, or `lastActiveAt` changed, preventing O(N) MainContentView.init cascade across windows

## [0.7.0] - 2026-02-25

### Added

- Quick search and filter rows can now be combined — when both are active, their WHERE conditions are joined with AND
- Foreign key columns now show a navigation arrow icon in each cell — click to open the referenced table filtered by the FK value

### Changed

- Metadata queries (columns, FKs, row count) now run on a dedicated parallel connection, eliminating 200-300ms delay for FK arrows and pagination count on initial table load
- Approximate row count from database metadata displays instantly with data; exact count refines silently in the background
- Show warning indicator on filter presets referencing columns not in current table
- Increase filter row height estimate for better accessibility support
- FK navigation now uses dedicated FilterStateManager.setFKFilter API instead of direct property manipulation
- Add syntax highlighting to Import SQL file preview
- XLSX export now enforces the Excel row limit (1,048,576) per sheet and uses autoreleasepool per row to reduce peak memory during large exports
- Multiline cell values now use a scrollable overlay editor instead of the constrained field editor, enabling proper vertical scrolling and line navigation during inline editing
- AnyChangeManager now uses a reference-type box for lazy initialization, avoiding Combine pipeline creation during SwiftUI body evaluation
- DataGridView identity check moved before AppSettingsManager read to skip settings access when nothing has changed
- DataGridView async column width write-back now uses an isWritingColumnLayout guard to prevent two-frame bounce
- Tab switch flushPendingSave debounced to skip redundant saves within 100ms of rapid tab switching
- SQL editor frame-change notification throttled to 50ms to avoid redundant syntax highlight viewport recalculation on every keystroke
- SQL editor text binding sync now uses O(1) NSString length pre-check before O(n) full string equality comparison
- Toolbar executing state now fires a single objectWillChange instead of double-publishing isExecuting and connectionState
- Row provider onChange handlers coalesced into a single trigger to avoid redundant InMemoryRowProvider rebuilds
- SQL import now uses file-size estimation instead of a separate counting pass, eliminating the double-parse overhead for large files
- History cleanup COUNT + DELETE now wrapped in a single transaction to reduce journal flushes
- SQLite `fetchTableMetadata` now caps row count scan at 100k rows to avoid full table scans on large tables
- SQLite `fetchIndexes` uses table-valued pragma functions in a single query instead of N+1 separate PRAGMA calls
- MySQL empty-result DESCRIBE fallback now only triggers for SELECT queries, avoiding redundant round-trips for non-SELECT statements
- Remove redundant `String(query)` copy in MariaDB query execution
- MySQL result fetching now uses `mysql_use_result` (streaming) instead of `mysql_store_result` (full buffering), so only the capped row count is held in memory instead of the entire server result set
- Instant pagination via approximate row count — MySQL/PostgreSQL tables now show "~N rows" immediately with data, then refine to exact count in background
- QueryTab uses value-based equality for SwiftUI diffing, eliminating unnecessary ForEach re-renders on tab array writes
- Cached static regex for `extractTableName`, `SQLiteDriver.stripLimitOffset`, and SQL function expressions to avoid per-call compilation
- Static NumberFormatter in status bar to avoid per-render locale resolution
- Batch `TableProTabSmart` field writes into single array store to avoid 14 CoW copies per query execution
- Tab persistence writes moved off main thread via `Task.detached`
- Single history entry per SQL import instead of per-statement recording
- WAL mode enabled for query history SQLite database
- Merged `fetchDatabaseMetadata` into single query for MySQL and PostgreSQL
- Health ping now uses dedicated metadata driver to avoid blocking user queries
- SSH tunnel setup extracted into shared helper to eliminate code duplication
- PostgreSQL DDL queries restructured with `async let` for cleaner dispatch (sequential on serial connection queue)
- Cancel query connection now uses 5-second connect timeout
- PostgreSQL connection parameters properly escaped for special characters
- SQLite `fetchAllColumns` overridden with single `sqlite_master` + `pragma_table_info` query
- Eliminated intermediate `[UInt8]` buffer in MySQL and PostgreSQL field extraction
- Column layout sync gated behind user-resize flag to skip O(n) loop on cursor moves
- Column width calculation uses monospace character arithmetic instead of per-row CoreText calls
- DataChangeManager maintains change index incrementally instead of full O(n) rebuild
- JSON export buffers writes per row instead of per field
- `SQLFormatterService` uses NSMutableString for keyword uppercasing and integer counter for placeholders
- SQLContextAnalyzer uses single alternation regex and single-pass state machine for string/comment detection
- `escapeJSONString` iterates UTF-8 bytes instead of grapheme clusters
- `AppSettingsStorage` caches JSONDecoder/JSONEncoder as stored properties
- `AppSettingsManager` stores validated settings in memory after didSet
- `FilterSettingsStorage` uses tracked key set instead of loading full plist
- Keychain saves use `SecItemAdd` + `SecItemUpdate` upsert pattern instead of delete + add
- Autocomplete `detectFunctionContext` uses index tracking instead of character-by-character string building

### Fixed

- Fix AND/OR filter logic mode ignored in query execution — preview showed correct OR logic but actual query always used AND
- Fix filter panel state (filters, visibility, quick search, logic mode) not preserved when switching between tabs
- Fix foreign key navigation filter being wiped when switching to a new tab (tab switch restore overwrote FK filter state)
- Fix pagination count appearing 200-300ms after data loads — approximate row count from database metadata now displays instantly with data, exact count refines silently in the background
- Fix foreign key navigation arrows and pagination count appearing with visible delay on initial table load — metadata now fetches on a dedicated parallel connection concurrent with the main query
- Fix LibPQ parameterized query using Swift `deallocate()` for `strdup`-allocated memory instead of `free()`
- FTS5 search input now sanitized to prevent parse errors from special characters like \*, OR, AND
- Fix SQL export corrupting newline/tab/backslash characters for PostgreSQL and SQLite (MySQL-style backslash escaping was incorrectly applied to all database types)
- Fix PostgreSQL SQL export failing to import when types/sequences already exist (`DROP IF EXISTS` now always emitted for dependent types and sequences)
- Fix PostgreSQL SQL export missing `CREATE TYPE` definitions for enum columns, causing import errors
- Fix PostgreSQL DDL tab not showing enum type definitions used by table columns
- Fix compilation error for PostgreSQL dependent sequences export (`fetchDependentSequences` missing from `DatabaseDriver` protocol)
- Fix PostgreSQL LIKE/NOT LIKE expressions missing `ESCAPE '\'` clause, causing wildcard escaping (`\%`, `\_`) to be treated as literal characters
- Fix SQLite regex filter silently degrading to LIKE substring match instead of being excluded from the WHERE clause

## [0.6.4] - 2026-02-23

### Fixed

- Fix PostgreSQL SQL export failing to fetch DDL for tables (passed quoted identifier instead of raw table name to catalog queries)

## [0.6.3] - 2026-02-23

### Changed

- Extract shared `performDirectTabSwitch` into `MainContentCoordinator` to eliminate duplicate tab-switch logic
- Welcome window now uses native macOS frosted glass translucency (NSVisualEffectView with behind-window blending)

### Fixed

- Auto-detect MySQL vs MariaDB server type from version string to use correct timeout variable (`max_execution_time` for MySQL, `max_statement_time` for MariaDB)
- Improved tab switching performance by caching row providers and change managers across SwiftUI render cycles
- Eliminated selection sync feedback loop causing redundant DataGridView updates during tab switch
- Enabled NSTableView row view recycling to reduce heap allocations during scrolling
- Reduced SwiftUI re-render cascades by batching @Published mutations during tab switch
- Improved DataGrid scrolling performance:
    - Row views now recycled via NSTableView's reuse pool instead of allocating new objects per scroll
    - Replaced O(n) String.count with O(1) NSString.length for large cell value truncation
    - Replaced expensive NSFontDescriptor.symbolicTraits checks with O(1) pointer equality on cached fonts
    - Added layerContentsRedrawPolicy and canDrawSubviewsIntoLayer to reduce compositing overhead
    - Cached NULL display string locally instead of per-cell singleton access
    - Cached AnyChangeManager to avoid per-render allocation with Combine subscriptions
    - Deferred accessibility label generation to when VoiceOver is active
    - Removed unnecessary async dispatch in focusedColumn, collapsed two reloadData calls into one

## [0.6.2] - 2026-02-23

### Changed

- Replace generic SwiftUI colors with native macOS system colors (`Color(nsColor: .system*)` instead of `Color.red/green/blue/orange`) for proper dark mode, vibrancy, and accessibility adaptation
- Replace hardcoded opacity on semantic colors with `quaternaryLabelColor`/`tertiaryLabelColor`
- Use `shadowColor` instead of `Color.black` for shadows
- Replace iOS-style Capsule badges with RoundedRectangle

## [0.6.1] - 2026-02-23

### Fixed

- Fixed all 45 performance issues identified in PERFORMANCE.md audit:
    - **Memory:** RowBuffer reference wrapper for QueryTab (MEM-1/2), index-based sort cache (MEM-3), streaming XLSX export with inline strings (MEM-4/15), driver-level row limits cap at 100K rows (MEM-5), removed redundant String deep copies (MEM-6), weak driver reference in SQLSchemaProvider (MEM-9), undo stack depth cap (MEM-10), dictionary-based tab pending changes (MEM-11), weak self in Task captures (MEM-12), clear cached data on disconnect (MEM-13), AI chat message cap (MEM-14)
    - **CPU:** Removed unicodeScalars.map in MariaDB/PostgreSQL drivers (CPU-1/2), cached 100+ regex patterns in SQLFormatterService (CPU-3/5/8/9/10), async Keychain reads (CPU-4), cached stripLimitOffset/extractTableName/isDangerousQuery regex (CPU-6/13/14), cached CSV decimal regex (CPU-7), O(1) change lookup index (CPU-11), removed unused loadPassword call (CPU-12)
    - **Data handling:** Auto-append LIMIT 10000 for unprotected queries (DAT-1), driver-level row limit cap for MySQL/PostgreSQL (DAT-2), SQLite row limit cap at 100K (DAT-3), batch fetchAllColumns via INFORMATION_SCHEMA (DAT-4), index permutation sort cache (DAT-5), cached InMemoryRowProvider in @State (DAT-6), clipboard 50K row cap (DAT-7), Int-based row IDs replacing UUID allocation (DAT-8)
    - **Network:** Phase 2 metadata cache check (NET-1), connect_timeout for LibPQ (NET-2), driver-level cancelQuery via mysql_kill/PQcancel/sqlite3_interrupt (NET-3), isLoading guard for sidebar (NET-4), reuse cached schema for AI chat (NET-5)
    - **I/O:** Throttled history cleanup (IO-1), async history storage migration (IO-2), consolidated onChange handlers (IO-3)

## [0.6.0] - 2026-02-22

### Added

- Inline AI suggestions (ghost text) in the SQL editor — auto-triggers on typing pause, Tab to accept, Escape to dismiss
- Schema-aware inline suggestions — AI now uses actual table/column names from the connected database (cached with 30s TTL, respects `includeSchema` and `maxSchemaTables` settings)
- AI feature highlight row on onboarding features page
- Added VoiceOver accessibility labels to custom controls: data grid (table view, column headers, cells), filter panel (logic toggle, presets, action buttons, filter row controls), toolbar buttons (connection switcher, database switcher, refresh, export, import, filter toggle, history toggle, inspector toggle), editor tab bar (tab items, close buttons, add tab button), and sidebar (table/view rows, search clear button)

### Changed

- Migrated notification observers in `MainContentCommandActions` from Combine publishers (`.publisher(for:).sink`) to async sequences (`for await` over `NotificationCenter.default.notifications(named:)`) — removes `AnyCancellable` storage in favor of `Task` handles with proper cancellation on deinit
- Migrated tab state persistence from UserDefaults to file-based storage in Application Support — prevents large JSON payloads from bloating the plist loaded at app launch, with automatic one-time migration of existing data
- Refactored menu and toolbar commands from NotificationCenter to `@FocusedObject` pattern — menu commands and toolbar buttons now call `MainContentCommandActions` methods directly instead of posting global notifications, with context-aware routing for structure view operations
- Redesigned connection form with tab-based layout (General / SSH Tunnel / SSL/TLS / Advanced), replacing the single-scroll layout
- Revamped connection form UI to use native macOS grouped form style (`Form`/`.formStyle(.grouped)`) with `LabeledContent` for automatic label-value alignment and `Section` headers — replacing the previous hand-rolled `VStack` layout with custom `FormField` component
- Removed unused `FormField` component and helper methods (`iconForType`, `colorForType`)
- SQLite connections now only show General and Advanced tabs (SSH/SSL hidden)
- Added async/await wrapper methods to `QueryHistoryStorage` — existing completion-handler API preserved for compatibility, new `async` overloads use `withCheckedContinuation` for modern Swift concurrency callers

### Fixed

- Fixed TOCTOU race condition in `SQLiteDriver` — replaced `nonisolated(unsafe)` + DispatchQueue pattern with a dedicated actor (`SQLiteConnectionActor`) that serializes all sqlite3 handle access, preventing concurrent task races on the connection state
- Consolidated multiple `.sheet(isPresented:)` modifiers in `MainContentView` into a single `.sheet(item:)` with an `ActiveSheet` enum — fixes SwiftUI anti-pattern where only the last `.sheet` modifier reliably activates
- Replaced blocking `Process.waitUntilExit()` calls in `SSHTunnelManager` with async `withCheckedContinuation`-based waiting, and replaced the fixed 1.5s sleep with active port probing — SSH tunnel setup no longer blocks the actor thread, keeping the UI responsive during connection
- Eliminated potential deadlocks in `MariaDBConnection` and `LibPQConnection` — replaced all `queue.sync` calls (in `disconnect`, `deinit`, `isConnected`, `serverVersion`) with lock-protected cached state and `queue.async` cleanup, preventing deadlocks when callbacks re-enter the connection queue
- SQL editor now respects the macOS accessibility text size preference (System Settings > Accessibility > Display > Text Size) — the user's chosen font size is scaled by the system's preferred text size factor, with live updates when the setting changes
- Fixed retain cycle in `UpdaterBridge` — `.assign(to:on:self)` retains self strongly; replaced with `.sink` using `[weak self]`
- Fixed leaked NotificationCenter observer in `SQLEditorCoordinator` — observer token is now stored and removed in `destroy()`
- Eliminated tab switching delay — replaced view teardown/recreation with `ZStack`+`ForEach` to keep NSViews alive, moved tab persistence I/O to background threads, skipped unnecessary change-tracking deep copies, and coalesced redundant inspector/sidebar updates during tab switch
- Reduced tab-switch CPU spikes from 40-60% to ~10-20% by eliminating redundant `reloadData()` calls: `configureForTable` no longer triggers a reload during tab switch (single controlled bump instead of 2-3), `onChange(of: resultColumns)` is suppressed while the switch is in progress, and `DataGridView.updateNSView` skips all heavy work when the data identity hasn't changed
- Table open now shows data instantly — split `executeQueryInternal` into two phases: rows display immediately after SELECT completes, metadata (columns, FKs, enums, row count) loads in the background without blocking the grid
- Eliminated 20-80ms overhead when clicking an already-open table in the sidebar — `openTableTab` short-circuits immediately, and `TableProTabSmart` no longer fires `@Published` when the selected tab hasn't changed
- Keychain `SecItemAdd` return values are now checked and logged — previously, failed writes (e.g. `errSecDuplicateItem`, `errSecInteractionNotAllowed`) were silently discarded, risking password loss
- Added `kSecAttrService` to all Keychain queries across `ConnectionStorage`, `LicenseStorage`, and `AIKeyStorage` — items now have a proper service identifier, preventing potential collisions with other apps
- Ensured proper cleanup for `@State` reference type tokens — tracked untracked `Task` instances in `ImportDialog` (file selection), `AIProviderEditorSheet` (model fetching, connection test), and added `onDisappear` cancellation to prevent leaked work after view dismissal
- Replaced `.onAppear` with `.task` for I/O operations in `ConnectionTagEditor` — uses SwiftUI-idiomatic lifecycle-tied loading instead of `onAppear` which can re-fire on navigation

## [0.5.0] - 2026-02-19

### Changed

- AI chat panel — native macOS inspector styling: removed iOS-style chat bubbles, flattened message layout with role headers and compact spacing, reduced heading sizes for narrow sidebar, inline typing indicator without pill background
- **AppKit → SwiftUI migration:** migrated 5 NSPopover controllers (Enum, Set, TypePicker, JSONEditor, ForeignKey) to SwiftUI content views with a shared `PopoverPresenter` utility — eliminates manual `NSEvent` monitors, `NSPopoverDelegate`, and singleton patterns
- **AppKit → SwiftUI migration:** replaced `KeyEventHandler` NSViewRepresentable with native `.onKeyPress()` modifiers (macOS 14+) in DatabaseSwitcherSheet and WelcomeWindowView
- **AppKit → SwiftUI migration:** replaced AppKit history panel (5 files: `HistoryPanelController`, `HistoryListViewController`, `QueryPreviewViewController`, `HistoryTableView`, `HistoryRowView`) with single pure SwiftUI `HistoryPanelView` using `HSplitView`, `List` with selection, context menus, and swipe-to-delete
- **AppKit → SwiftUI migration:** replaced `ExportTableOutlineView` (NSOutlineView, 757 lines across 2 files) with SwiftUI `ExportTableTreeView` using `List`, `DisclosureGroup`, and tristate checkboxes (~146 lines)
- **Design tokens:** replaced hardcoded `Color.secondary.opacity(0.6)` with system `Color(nsColor: .tertiaryLabelColor)` in `DesignConstants` and `ToolbarDesignTokens` for proper semantic color

### Added

- AI chat panel shows "Set Up AI Provider" empty state when no AI provider is configured, with a button to open Settings
- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- AI chat markdown rendering — replaced custom per-line AttributedString parsing with MarkdownUI library for full CommonMark + GitHub Flavored Markdown support (proper lists, tables, blockquotes, headers, strikethrough)
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button
- Tab reuse setting — opt-in option in Settings > Tabs to reuse clean table tabs when clicking a new table in the sidebar (off by default)
- Structure view: full undo/redo support (⌘Z / ⇧⌘Z) for all column, index, and foreign key operations
- Structure view: database-specific type picker popover for the Type column — searchable, grouped by category (Numeric, String, Date & Time, Binary, Other), supports freeform input for parametric types like `VARCHAR(255)`
- Structure view: YES/NO dropdown menu for Nullable, Auto Inc, and Unique columns (replaces freeform text input)
- Structure view: "Don't show again" toggle in SQL preview sheet now correctly skips the review step on future saves
- SQL autocomplete: new clause types — RETURNING, UNION/INTERSECT/EXCEPT, OVER/PARTITION BY, USING, DROP/CREATE INDEX/VIEW
- SQL autocomplete: smart clause transition suggestions (e.g., WHERE after FROM, HAVING after GROUP BY, LIMIT after ORDER BY)
- SQL autocomplete: qualified column suggestions (`table.column`) in JOIN ON clauses and `table.*` in SELECT
- SQL autocomplete: compound keyword suggestions — `IS NULL`, `IS NOT NULL`, `NULLS FIRST`, `NULLS LAST`, `ON CONFLICT`, `ON DUPLICATE KEY UPDATE`
- SQL autocomplete: richer column metadata in suggestions (primary key, nullability, default value, comment)
- SQL autocomplete: keyword documentation in completion popover
- SQL autocomplete: expanded keyword and function coverage — window functions, PostgreSQL/MySQL-specific, transaction, DCL, aggregate, datetime, string, numeric, JSON
- SQL autocomplete: context-aware suggestions for ALTER TABLE, INSERT INTO, CREATE TABLE, and COUNT(\*)
- SQL autocomplete: improved fuzzy match scoring — prefix and contains matches rank above fuzzy-only matches
- Keyboard shortcut customization in Settings > Keyboard — rebind any menu shortcut via press-to-record UI, with conflict detection and "Reset to Defaults" support
- Keyboard shortcut for Switch Connection (`⌘⌥C`) — quickly open the connection switcher popover from the menu or keyboard

### Changed

- **Layout architecture:** replaced `SplitViewMinWidthEnforcer` NSViewRepresentable hack with proper AppDelegate-based inspector split view configuration — eliminates KVO observation, 300ms sleep, and recursive view tree traversal
- **Inspector data flow:** replaced manual snapshot syncing (`syncRightPanelSnapshotData()` + 5 `onChange` handlers) with `InspectorContext` value type passed directly through the view hierarchy via `@Binding`
- **Right panel state:** `RightPanelState` no longer holds snapshot copies of coordinator data or a weak coordinator reference — it now only manages panel visibility, tab state, and owned objects
- **AI chat panel:** receives `currentQuery: String?` parameter instead of a `MainContentCoordinator` reference — better separation of concerns
- **Sidebar save:** replaced `.saveSidebarChanges` notification with direct closure (`RightPanelState.onSave`) set by the notification handler
- Structure tab grid columns now auto-size to fit content on data load
- Structure view column headers and status messages are now localized
- SQL autocomplete: 50ms debounce for completion triggers to reduce unnecessary work
- SQL autocomplete: fuzzy matching rewritten for O(1) character access performance

### Fixed

- **Structure view:** undo/redo (⌘Z / ⇧⌘Z) now works for all schema editing operations — previously non-functional
- **Structure view:** undo-delete no longer duplicates existing rows in the grid
- **Structure view:** deleting a new (unsaved) item then undoing correctly re-adds it
- **Structure view:** save button now disabled when validation errors exist (empty column names/types)
- **Structure view:** validation now rejects indexes and foreign keys referencing columns pending deletion
- **Structure view:** multi-column foreign keys are correctly preserved instead of being truncated to single-column
- **Structure view:** renaming a MySQL/MariaDB column now uses `CHANGE COLUMN` instead of `MODIFY COLUMN` (which cannot rename)
- **Structure view:** eliminated redundant `discardChanges()` and `loadSchemaForEditing()` calls on save and initial load
- **PostgreSQL:** DDL tab now includes PRIMARY KEY, UNIQUE, CHECK, and FOREIGN KEY constraints plus standalone indexes
- **PostgreSQL:** primary key columns are now correctly detected and displayed in the structure grid
- **Security:** escape table and database names in all driver schema queries to prevent SQL injection from names containing special characters
- **SQL editor:** undo/redo (⌘Z / ⇧⌘Z) now works correctly (was blocked by responder chain selector mismatch)
- **SQL autocomplete:** clause detection now works correctly inside subqueries
- **SQL autocomplete:** block comment detection no longer treats `--` inside `/* */` as a line comment
- **SQL autocomplete:** database-specific type keywords (e.g., PostgreSQL `JSONB`, MySQL `ENUM`) now appear in suggestions
- **SQL autocomplete:** schema suggestions no longer disappear after CREATE TABLE
- **SQL autocomplete:** function completion now inserts `COUNT()` with cursor between parentheses instead of `COUNT(`
- **SQL autocomplete:** RETURNING suggestions now work after INSERT INTO and after closed `VALUES (...)` parentheses
- **SQL autocomplete:** CREATE INDEX ON suggests columns from the referenced table instead of table names
- **SQL autocomplete:** transition keywords (WHERE, JOIN, ORDER BY) no longer buried under columns at clause boundaries
- **SQL autocomplete:** schema-qualified names (e.g., `schema.table.column`) handled correctly
- **Data grid:** column order no longer flashes/swaps when sorting (stable identifiers for layout persistence)
- **Data grid:** "Copy Column Name" and "Filter with column" context menu actions no longer copy sort indicators (e.g., "name 1▲")
- **SQL generation:** ALTER TABLE, DDL, and SQL Preview statements now consistently end with a semicolon
- **AI chat:** "Ask Each Time" connection policy now shows a confirmation dialog before sending data to AI — previously silently fell through to "Always Allow"

### Removed

- Deleted unused `StructureTableCoordinator.swift` (~275 lines of dead code)
- Deleted 5 dead NSToolbar files (`ToolbarController`, `ToolbarWindowConfigurator`, `ToolbarItemFactory`, `ToolbarItemIdentifier`, `ToolbarHostingViews`) — never referenced by active code
- Removed `SplitViewMinWidthEnforcer` struct from `ContentView.swift`
- Removed `.saveSidebarChanges` notification definition and subscription

## [0.4.0] - 2026-02-16

### Added

- SQL Preview button (eye icon) in toolbar to review all pending SQL statements before committing changes (⌘⇧P)
- Multi-column sorting: Shift+click column headers to add columns to the sort list; regular click replaces with single sort. Sort priority indicators (1▲, 2▼) are shown in column headers when multiple columns are sorted
- "Copy with Headers" feature (Shift+Cmd+C) to copy selected rows with column headers as the first TSV line, also available via context menu in the data grid
- Column width persistence within tab session: resized columns retain their width across pagination, sorting, and filtering reloads
- Dangerous query confirmation dialog for `DELETE`/`UPDATE` statements without a `WHERE` clause — summarizes affected queries before execution
- SQL editor horizontal scrolling for long lines without word wrapping
- Scroll-to-match navigation in SQL editor find panel
- GitHub Sponsors funding configuration

### Changed

- Raise minimum macOS version from 13.5 (Ventura) to 14.0 (Sonoma)
- Change Export/Import keyboard shortcuts from ⌘E/⌘I to ⇧⌘E/⇧⌘I to avoid conflicts with standard text editing shortcuts
- Configure URLSession to wait for network connectivity in analytics and license services
- Improve SQL statement parser to handle backslash escapes within string literals, preventing false positives in dangerous query detection

### Fixed

- Fix SQL editor not updating colors when switching between light and dark mode
- Fix sidebar retaining stale table selections and pending operations for tables that no longer exist after a database refresh

## [0.3.2] - 2026-02-14

### Fixed

- Fix launch crash on macOS 13 (Ventura) x86_64 caused by accessing `NSApp.appearance` before `NSApplication` is initialized during settings singleton setup

## [0.3.1] - 2026-02-14

### Fixed

- Fix syntax highlighting not applying after paste in SQL editor — defer frame-change notification so the visible range recalculates after layout processes the new text
- Fix data grid not refreshing after inserting a new row by incrementing `reloadVersion` on row insertion

## [0.3.0] - 2026-02-13

### Added

- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button

- Anonymous usage analytics with opt-out toggle in Settings > General > Privacy — sends lightweight heartbeat (OS version, architecture, locale, database types) every 24 hours to help improve TablePro; no personal data or queries are collected
- ENUM/SET column editor: double-click ENUM columns to select from a searchable dropdown popover, SET columns show a multi-select checkbox popover with OK/Cancel buttons
- PostgreSQL user-defined enum type support via `pg_enum` catalog lookup
- SQLite CHECK constraint pseudo-enum detection (e.g., `CHECK(col IN ('a','b','c'))`)
- Language setting in General preferences (System, English, Vietnamese) with full Vietnamese localization (637 strings)
- Connection health monitoring with automatic reconnection for MySQL/MariaDB and PostgreSQL — pings every 30 seconds, retries 3 times with exponential backoff (2s/4s/8s) on failure
- Manual "Reconnect" toolbar button appears when connection is lost or in error state

### Changed

- Migrate `Libs/*.a` static libraries to Git LFS tracking to reduce repository clone size
- Remove stale `.gitignore` entries for architecture-specific MariaDB libraries
- Replace `filter { }.count` with `count(where:)` across 7 files for more efficient collection counting
- Replace `print()` with `Logger` in documentation examples and remove from `#Preview` blocks
- Replace `.count > 0` with `!.isEmpty` in documentation example

### Fixed

- Fix launch crash on macOS 13 caused by missing `asyncAndWait` symbol in CodeEditSourceEditor 0.15.2 (API requires macOS 14+); updated dependency to track `main` branch which uses `sync` instead
- Escape single quotes in PostgreSQL `pg_enum` lookup and SQLite `sqlite_master` queries to prevent SQL injection
- ENUM column nullable detection now uses actual schema metadata instead of heuristic rawType check
- PostgreSQL primary key modification now queries the actual constraint name from `pg_constraint` instead of assuming the `{table}_pkey` naming convention, supporting tables with custom constraint names
- Align Xcode `SWIFT_VERSION` build setting from 5.0 to 5.9 to match `.swiftformat` target version

## [0.2.0] - 2026-02-11

### Added

- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button

- SSL/TLS connection support for MySQL/MariaDB and PostgreSQL with configurable modes (Disabled, Preferred, Required, Verify CA, Verify Identity) and certificate file paths
- RFC 4180-compliant CSV parser for clipboard paste with auto-detection of CSV vs TSV format
- Explain Query button in SQL editor toolbar and menu item (⌥⌘E) for viewing execution plans
- Connection switcher popover for quick switching between active/saved connections from the toolbar
- Date/time picker popover for editing date, datetime, timestamp, and time columns in the data grid
- Read-only connection mode with toggle in connection form, toolbar badge, and UI-level enforcement (disables editing, row operations, and save changes)
- Configurable query execution timeout in Settings > General (default 60s, 0 = no limit) with per-driver enforcement via `statement_timeout` (PostgreSQL), `max_execution_time` (MySQL), `max_statement_time` (MariaDB), and `sqlite3_busy_timeout` (SQLite)
- Foreign key lookup dropdown for FK columns in the data grid — shows a searchable popover with values from the referenced table, displaying both the ID and a descriptive display column
- JSON column editor popover for JSON/JSONB columns with pretty-print formatting, compact mode, real-time validation, and explicit save/cancel buttons
- Excel (.xlsx) export format with lightweight pure-Swift OOXML writer — supports shared strings deduplication, bold header rows, numeric type detection, sheet name sanitization, and multi-table export to separate worksheets
- View management: Create View (opens SQL editor with template), Edit View Definition (fetches and opens existing definition), and Drop View from sidebar context menu. Adds `fetchViewDefinition()` to all database drivers (MySQL, PostgreSQL, SQLite)

### Fixed

- Fixed crash on launch on macOS 13 (Ventura) caused by missing Swift runtime symbol
- Fix redo functionality in data grid (Cmd+Shift+Z now works correctly)
- Fix redo stack not being cleared when new changes are made (standard undo/redo behavior)
- Fix `canRedo()` always returning false in data grid coordinator
- Wire undo/redo callbacks directly to data grid for proper responder chain validation
- Fix MariaDB connection error 1193 "Unknown system variable 'max_execution_time'" by using the correct `max_statement_time` variable for MariaDB
- Query timeout errors no longer prevent database connections from being established

### Changed

- Replace all `print()` statements with structured OSLog `Logger` across 25 files for better debugging via Console.app

## [0.1.1] - 2026-02-09

### Added

- AI chat panel — right-side panel for AI-assisted SQL queries with multi-provider support (Claude, OpenAI, OpenRouter, Ollama, custom endpoints)
- AI provider settings — configure multiple AI providers in Settings > AI with API key management (Keychain), endpoint configuration, model selection, and connection testing
- AI feature routing — map AI features (Chat, Explain Query, Fix Error, Inline Suggestions) to specific providers and models
- AI schema context — automatically includes database schema, current query, and query results in AI conversations for context-aware assistance
- AI chat code blocks — SQL code blocks in AI responses include Copy and Insert to Editor buttons
- Per-connection AI policy — control AI access per connection (Always Allow, Ask Each Time, Never) in the connection form
- Toggle AI Chat keyboard shortcut (`⌘⇧L`) and toolbar button

- Auto-update support via Sparkle 2 framework (EdDSA signed)
- "Check for Updates..." menu item in TablePro menu
- Software Update section in Settings > General with auto-check toggle
- CI appcast generation and auto-deploy on tagged releases

- Migrate SQL editor to CodeEditSourceEditor (tree-sitter powered)
- Multi-statement SQL execution support
- "Show Structure" context menu for sidebar tables
- Improved filter panel UI/UX
- SwiftUI EditorTabBar (replacing AppKit NativeTabBarView)
- GPL v3 license

### Fixed

- Fix MySQL 8+ connections failing with `caching_sha2_password` plugin error by rebuilding libmariadb.a with the auth plugin compiled statically
- Fix Delete key on data grid row from marking table as deleted
- Downgrade all APIs to support macOS 13.5 (Ventura)
- Code review fixes for multi-statement execution

### Changed

- CI release notes now read from CHANGELOG.md instead of auto-generating from commits
- Removed `prepare-libs` CI job to speed up build pipeline (~5 min savings)
- Add SPM Package.resolved for CodeEditSourceEditor dependencies
- Add Claude Code project settings
- Update build/test commands with `-skipPackagePluginValidation`

## [0.1.0] - 2026-02-05

### Initial Public Release

TablePro is a native macOS database client built with SwiftUI and AppKit, designed as a fast, lightweight alternative to TablePlus.

### Features

- **Database Support**
    - MySQL/MariaDB connections
    - PostgreSQL support
    - SQLite database files
    - SSH tunneling for secure remote connections

- **SQL Editor**
    - Syntax highlighting with TreeSitter
    - Intelligent autocomplete for tables, columns, and SQL keywords
    - Multi-tab editing support
    - Query execution with result grid

- **Data Management**
    - Interactive data grid with sorting and filtering
    - Inline editing capabilities
    - Add, edit, and delete rows
    - Pagination for large result sets
    - Export data (CSV, JSON, SQL)

- **Database Explorer**
    - Browse tables, views, and schema
    - View table structure and indexes
    - Quick table information and statistics
    - Search across database objects

- **User Experience**
    - Native macOS design with SwiftUI
    - Dark mode support
    - Customizable keyboard shortcuts
    - Query history tracking
    - Multiple database connections

- **Developer Features**
    - Import/export connection configurations
    - Custom SQL query templates
    - Performance optimized for large datasets

[Unreleased]: https://github.com/TableProApp/TablePro/compare/v0.31.2...HEAD
[0.31.2]: https://github.com/TableProApp/TablePro/compare/v0.31.1...v0.31.2
[0.31.1]: https://github.com/TableProApp/TablePro/compare/v0.31.0...v0.31.1
[0.31.0]: https://github.com/TableProApp/TablePro/compare/v0.30.1...v0.31.0
[0.30.1]: https://github.com/TableProApp/TablePro/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/TableProApp/TablePro/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/TableProApp/TablePro/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/TableProApp/TablePro/compare/v0.27.5...v0.28.0
[0.27.5]: https://github.com/TableProApp/TablePro/compare/v0.27.4...v0.27.5
[0.27.4]: https://github.com/TableProApp/TablePro/compare/v0.27.3...v0.27.4
[0.27.3]: https://github.com/TableProApp/TablePro/compare/v0.27.2...v0.27.3
[0.27.2]: https://github.com/TableProApp/TablePro/compare/v0.27.1...v0.27.2
[0.27.1]: https://github.com/TableProApp/TablePro/compare/v0.27.0...v0.27.1
[0.27.0]: https://github.com/TableProApp/TablePro/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/TableProApp/TablePro/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/TableProApp/TablePro/compare/v0.24.2...v0.25.0
[0.24.2]: https://github.com/TableProApp/TablePro/compare/v0.24.1...v0.24.2
[0.24.1]: https://github.com/TableProApp/TablePro/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/TableProApp/TablePro/compare/v0.23.2...v0.24.0
[0.23.2]: https://github.com/TableProApp/TablePro/compare/v0.23.1...v0.23.2
[0.23.1]: https://github.com/TableProApp/TablePro/compare/v0.23.0...v0.23.1
[0.23.0]: https://github.com/TableProApp/TablePro/compare/v0.22.1...v0.23.0
[0.22.1]: https://github.com/TableProApp/TablePro/compare/v0.22.0...v0.22.1
[0.22.0]: https://github.com/TableProApp/TablePro/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/TableProApp/TablePro/compare/v0.20.4...v0.21.0
[0.20.4]: https://github.com/TableProApp/TablePro/compare/v0.20.3...v0.20.4
[0.20.3]: https://github.com/TableProApp/TablePro/compare/v0.20.2...v0.20.3
[0.20.2]: https://github.com/TableProApp/TablePro/compare/v0.20.1...v0.20.2
[0.20.1]: https://github.com/TableProApp/TablePro/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/TableProApp/TablePro/compare/v0.19.1...v0.20.0
[0.19.1]: https://github.com/TableProApp/TablePro/compare/v0.19.0...v0.19.1
[0.19.0]: https://github.com/TableProApp/TablePro/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/TableProApp/TablePro/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/TableProApp/TablePro/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/TableProApp/TablePro/compare/v0.16.1...v0.17.0
[0.16.1]: https://github.com/TableProApp/TablePro/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/TableProApp/TablePro/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/TableProApp/TablePro/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/TableProApp/TablePro/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/TableProApp/TablePro/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/TableProApp/TablePro/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/TableProApp/TablePro/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/TableProApp/TablePro/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/TableProApp/TablePro/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/TableProApp/TablePro/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/TableProApp/TablePro/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/TableProApp/TablePro/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/TableProApp/TablePro/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/TableProApp/TablePro/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/TableProApp/TablePro/compare/v0.6.4...v0.7.0
[0.6.4]: https://github.com/TableProApp/TablePro/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/TableProApp/TablePro/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/TableProApp/TablePro/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/TableProApp/TablePro/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/TableProApp/TablePro/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/TableProApp/TablePro/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/TableProApp/TablePro/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/TableProApp/TablePro/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/TableProApp/TablePro/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/TableProApp/TablePro/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/TableProApp/TablePro/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/TableProApp/TablePro/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/TableProApp/TablePro/releases/tag/v0.1.0
