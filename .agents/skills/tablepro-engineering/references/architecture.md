# Architecture

## Project Overview

TablePro is a native macOS database client built on SwiftUI and AppKit. It targets macOS 14.0, builds a Universal Binary (arm64 and x86_64), and compiles in Swift 5 language mode (`Configs/Base.xcconfig`).

- **Source** lives in `TablePro/`: `Core/` (business logic, services), `Views/` (UI), `Models/` (data structures), `ViewModels/`, `Extensions/`, `Theme/`
- **Plugins** live in `Plugins/`: `.tableplugin` bundles plus the `TableProPluginKit` shared framework.
    - **Bundled in app** (the 14 targets in the app's copy-to-PlugIns phase in `project.yml`): MySQL, PostgreSQL, SQLite, ClickHouse, Redis, CSV export, JSON export, SQL export, XLSX export, MQL export, SQL import, JSON import, CSV import, CSV inspector. Shipped only inside the app bundle. **Never publish bundled plugins to the registry.** Updates ride with the next app release.
    - **Registry-only** (the other 16): MongoDB, Oracle, DuckDB, MSSQL, Cassandra, Etcd, CloudflareD1, DynamoDB, BigQuery, LibSQL, Snowflake, Elasticsearch, Beancount, SurrealDB, Teradata, Trino. Distributed via [TableProApp/plugins](https://github.com/TableProApp/plugins) `plugins.json`, installed into the user plugins directory.
- **C bridges**: Each plugin contains its own C bridge module (e.g., `Plugins/MySQLDriverPlugin/CMariaDB/`, `Plugins/PostgreSQLDriverPlugin/CLibPQ/`)
- **Static libs** live in `Libs/` as pre-built `.a` files, with iOS xcframeworks in `Libs/ios/`. Both are downloaded by `scripts/download-libs.sh` and are not in git.
- **SPM deps**: declared in `project.yml`. Vendored local packages under `LocalPackages/` (CodeEditSourceEditor, CodeEditTextView, CodeEditLanguages) and `Packages/` (TableProCore, TableProOracle); remote packages are Sparkle, swift-certificates and Yams. Revisions are pinned by the tracked `Package.resolved` inside each generated `.xcodeproj`.


### Project Generation

`TablePro.xcodeproj` and `TableProMobile/TableProMobile.xcodeproj` are **generated artifacts**. They are gitignored and must never be hand-edited or committed. The source of truth is:

- `project.yml` / `TableProMobile/project.yml`: targets, sources, dependencies, schemes, and per-target build settings
- `Configs/*.xcconfig`: project-wide and per-configuration build settings, shared by both projects
- `Configs/Version.xcconfig`: the app's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, read by the release skill and by `build-plugin.yml`
- `Configs/Secrets.xcconfig`: gitignored, pulled in with `#include?`, holds `ANALYTICS_HMAC_SECRET` and per-developer signing overrides. `Configs/Secrets.xcconfig.example` is the template.

Run `scripts/generate-project.sh` after editing any of those, and after adding, moving, or deleting a source file: XcodeGen globs sources at generation time, so a new file is not in the project until you regenerate. Changing signing in the Xcode UI is pointless, because the next generate discards it; set `TABLEPRO_DEVELOPMENT_TEAM` and `TABLEPRO_APP_BUNDLE_IDENTIFIER` in `Configs/Secrets.xcconfig` instead.

The 30 plugin bundles share one `DriverPlugin` target template; a plugin declares only its folder, principal class, and any C-library link flags. Every target gets a shared scheme named after it, which is what `scripts/build-plugin.sh -scheme <PluginTarget>` builds. The `AllPlugins` aggregate target compile-checks all 30, including the registry-only ones the app does not embed.


- Editor tabs are drawn by `EditorTabStrip`, not by native window tabs. A window belongs to exactly one `NSWindow` tab group and that group's bar shows every window in it, so a window hosting several connections could only ever show all of their tabs interleaved. Window tabbing itself stays on AppKit's terms: `TabWindowController` leaves `tabbingMode` at `.automatic`, which is the user's own System Settings preference, and never forces `.preferred`.
- Cursor model: `cursorPositions: [CursorPosition]` (multi-cursor via CodeEditSourceEditor)

### Window Close (Cmd+W)

`EditorWindow` (NSWindow subclass in `TabWindowController.swift`) overrides `performClose:` to route Cmd+W through `closeTab()`. SwiftUI's `.commands { Button(...).keyboardShortcut("w") }` does NOT replace AppKit's built-in "File > Close", both fire, and AppKit's wins. The NSWindow subclass is the correct native pattern.


### Storage Patterns

| What                 | How              | Where                                       |
| -------------------- | ---------------- | ------------------------------------------- |
| Connection passwords | Keychain         | `ConnectionStorage`                         |
| User preferences     | UserDefaults     | `AppSettingsStorage` / `AppSettingsManager` |
| Query history        | SQLite FTS5      | `QueryHistoryStorage`                       |
| Tab state            | JSON persistence | `TabPersistenceService` / `TabStateStorage` |
| Filter defaults      | UserDefaults     | `FilterSettingsStorage` (default column/operator, panel state) |
| Filter presets       | UserDefaults     | `FilterPresetStorage`                       |
| Per-table filters    | JSON files       | `FilterSettingsStorage` (one file per connection + database + schema + table; saves the valid working set, each row's enabled flag included) |
| Favorite tables      | UserDefaults     | `FavoriteTablesStorage` (per connection + database + schema; iCloud-synced) |
| Tree database filter | UserDefaults     | `DatabaseTreeFilterStorage` (per connection; selected database set, empty = show all; device-local). Live value held in `SharedSidebarState`. |
| Recent tables        | UserDefaults     | `RecentTablesStore` (per connection, keyed by database, last 10 each; device-local). Live value held in `SharedSidebarState`, recorded at the `QueryTabManager` open chokepoint. |
| History drawer state | UserDefaults     | `HistoryPanelPreferencesStorage` (per connection; visibility, connection scope, source/date/outcome filters; device-local). Live value held in `HistoryPanelState.forConnection`, cleared alongside `SharedSidebarState` when a session ends. |
| Trusted external links | UserDefaults   | `ExternalConnectionTrustStore` (keyed by database type + host + database + username + URL `name`, never the port; loopback hosts only, enforced on read and write). Consulted by `ExternalConnectionGate` before the external-URL confirmation alert. |
