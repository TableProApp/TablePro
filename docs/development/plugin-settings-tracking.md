# Plugin Settings — Progress Tracking

Analysis date: 2026-03-11 (updated).

## Current State Summary

The plugin settings system has two dimensions:

1. **Plugin management** (Settings > Plugins) — enable/disable, install/uninstall. Fully working.
2. **Per-plugin configuration** — plugins conforming to `SettablePlugin` protocol get automatic persistence via `loadSettings()`/`saveSettings()` and expose `settingsView()` via the `SettablePluginDiscoverable` type-erased witness. All 5 export plugins and 1 import plugin use this pattern. Driver plugins have zero configurable settings but can adopt `SettablePlugin` when needed.

Plugin enable/disable state lives in `UserDefaults["com.TablePro.disabledPlugins"]` (namespaced, with legacy key migration).

---

## Plugin Management UI

| Feature                                                  | Status | File                                                | Notes                                                       |
| -------------------------------------------------------- | ------ | --------------------------------------------------- | ----------------------------------------------------------- |
| Installed plugins list with toggle                       | Done   | `Views/Settings/Plugins/InstalledPluginsView.swift` | One row per `PluginEntry`, inline detail expansion          |
| Enable/disable toggle (live)                             | Done   | `Core/Plugins/PluginManager.swift:382`              | Immediate capability register/unregister, no restart needed |
| Plugin detail (version, bundle ID, source, capabilities) | Done   | `Views/Settings/Plugins/InstalledPluginsView.swift` | Shown on row expansion                                      |
| Install from file (.tableplugin, .zip)                   | Done   | `Views/Settings/Plugins/InstalledPluginsView.swift` | NSOpenPanel + drag-and-drop                                 |
| Uninstall user plugins                                   | Done   | `Views/Settings/Plugins/InstalledPluginsView.swift` | Destructive button with AlertHelper.confirmDestructive      |
| Restart-required banner                                  | Done   | `Views/Settings/Plugins/InstalledPluginsView.swift` | Orange dismissible banner after uninstall                   |
| Browse registry                                          | Done   | `Views/Settings/Plugins/BrowsePluginsView.swift`    | Remote manifest from GitHub, search + category filter       |
| Registry install with progress                           | Done   | `Views/Settings/Plugins/RegistryPluginRow.swift`    | Download + SHA-256 verification, multi-phase progress       |
| Contextual install prompt (connection flow)              | Done   | `Views/Connection/PluginInstallModifier.swift`      | Alert when opening DB type with missing driver              |
| Code signature verification                              | Done   | `Core/Plugins/PluginManager.swift:586`              | Team ID `D7HJ5TFYCU` for user-installed plugins            |

## Per-Plugin Configuration

### Export Plugins

| Plugin | Options Model                                                                                               | Options View            | Persistence                          | Status |
| ------ | ----------------------------------------------------------------------------------------------------------- | ----------------------- | ------------------------------------ | ------ |
| CSV    | `CSVExportOptions` — delimiter, quoting, null handling, formula sanitize, line breaks, decimals, header row | `CSVExportOptionsView`  | `PluginSettingsStorage` (persisted)  | Done   |
| XLSX   | `XLSXExportOptions` — header row, null handling                                                             | `XLSXExportOptionsView` | `PluginSettingsStorage` (persisted)  | Done   |
| JSON   | `JSONExportOptions` — pretty print, null values, preserve-as-strings                                        | `JSONExportOptionsView` | `PluginSettingsStorage` (persisted)  | Done   |
| SQL    | `SQLExportOptions` — gzip, batch size                                                                       | `SQLExportOptionsView`  | `PluginSettingsStorage` (persisted)  | Done   |
| MQL    | `MQLExportOptions`                                                                                          | `MQLExportOptionsView`  | `PluginSettingsStorage` (persisted)  | Done   |

All export plugins conform to `SettablePlugin` which provides automatic `loadSettings()`/`saveSettings()` backed by `PluginSettingsStorage(pluginId:)`. Options are stored in `UserDefaults` keyed as `com.TablePro.plugin.<id>.settings`, encoded via `JSONEncoder`.

### Import Plugins

| Plugin     | Options Model    | Options View           | Persistence | Status                                           |
| ---------- | ---------------- | ---------------------- | ----------- | ------------------------------------------------ |
| SQL Import | `SQLImportOptions` (Codable struct) | `SQLImportOptionsView` | `PluginSettingsStorage` (persisted)  | Done |

### Driver Plugins

All 9 driver plugins have zero per-plugin settings. They can adopt `SettablePlugin` when settings are needed.

---

## Known Issues & Gaps

### High Priority

None — previously tracked high-priority issues have been resolved.

### Medium Priority

None — previously tracked medium-priority issues have been resolved.

### Low Priority

| Issue                        | Description                                                                                                    | Impact                                        |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| _(none)_                     | All previously tracked low-priority issues have been resolved                                                   |                                               |

### Resolved (since initial analysis)

| Issue                                        | Resolution                                                                                              |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Export options not persisted                  | All 5 export plugins now use `PluginSettingsStorage` with `Codable` options models                      |
| `disabledPlugins` key not namespaced         | Now uses `"com.TablePro.disabledPlugins"` with legacy key migration (`PluginManager.swift:15-16,50-58`) |
| 4 dead capability types                      | Removed — `PluginCapability` now only has 3 cases: `databaseDriver`, `exportFormat`, `importFormat`     |
| `PluginInstallTracker.markInstalling()` unused | Now called in `BrowsePluginsView.swift:185` when download fraction reaches 1.0                         |
| SQL import options not persisted             | `SQLImportOptions` converted to `Codable` struct with `PluginSettingsStorage` persistence               |
| `additionalConnectionFields` hardcoded       | Connection form Advanced tab now dynamically renders fields from `DriverPlugin.additionalConnectionFields` with `ConnectionField.FieldType` support (text, secure, dropdown) |
| No driver plugin settings UI                 | `DriverPlugin.settingsView()` protocol method added with `nil` default; rendered in InstalledPluginsView |
| No settings protocol in SDK                  | `SettablePlugin` protocol added to `TableProPluginKit` with `loadSettings()`/`saveSettings()` and `SettablePluginDiscoverable` type-erased witness; all 6 plugins migrated |
| Hardcoded registry URL                       | `RegistryClient` now reads custom URL from UserDefaults with ETag invalidation on URL change            |
| `needsRestart` not persisted                 | Backed by UserDefaults, cleared on next plugin load cycle                                               |

---

## Recommended Next Steps

Steps 1-3 have been completed. All plugins with settings now use the `SettablePlugin` protocol.

### Future — Driver plugin settings

- When driver plugins need per-plugin configuration (timeout, SSL, query behavior), they can adopt `SettablePlugin` using the same pattern as export/import plugins

---

## Key Files

| Component                      | Path                                                             |
| ------------------------------ | ---------------------------------------------------------------- |
| Settings tab container         | `TablePro/Views/Settings/PluginsSettingsView.swift`              |
| Installed list + toggle        | `TablePro/Views/Settings/Plugins/InstalledPluginsView.swift`     |
| Browse registry                | `TablePro/Views/Settings/Plugins/BrowsePluginsView.swift`        |
| Registry row + install         | `TablePro/Views/Settings/Plugins/RegistryPluginRow.swift`        |
| Registry detail                | `TablePro/Views/Settings/Plugins/RegistryPluginDetailView.swift` |
| PluginManager                  | `TablePro/Core/Plugins/PluginManager.swift`                      |
| Registry extension             | `TablePro/Core/Plugins/Registry/PluginManager+Registry.swift`    |
| Registry client                | `TablePro/Core/Plugins/Registry/RegistryClient.swift`            |
| Registry models                | `TablePro/Core/Plugins/Registry/RegistryModels.swift`            |
| Install tracker                | `TablePro/Core/Plugins/Registry/PluginInstallTracker.swift`      |
| Download count service         | `TablePro/Core/Plugins/Registry/DownloadCountService.swift`      |
| Plugin models                  | `TablePro/Core/Plugins/PluginModels.swift`                       |
| Plugin settings storage        | `Plugins/TableProPluginKit/PluginSettingsStorage.swift`          |
| SDK — settable protocol        | `Plugins/TableProPluginKit/SettablePlugin.swift`                 |
| Connection install prompt      | `TablePro/Views/Connection/PluginInstallModifier.swift`          |
| SDK — base protocol            | `Plugins/TableProPluginKit/TableProPlugin.swift`                 |
| SDK — driver protocol          | `Plugins/TableProPluginKit/DriverPlugin.swift`                   |
| SDK — export protocol          | `Plugins/TableProPluginKit/ExportFormatPlugin.swift`             |
| SDK — import protocol          | `Plugins/TableProPluginKit/ImportFormatPlugin.swift`             |
| SDK — capabilities             | `Plugins/TableProPluginKit/PluginCapability.swift`               |
| SDK — connection fields        | `Plugins/TableProPluginKit/ConnectionField.swift`                |
| CSV export (representative)    | `Plugins/CSVExportPlugin/CSVExportPlugin.swift`                  |
| SQL import plugin              | `Plugins/SQLImportPlugin/SQLImportPlugin.swift`                  |
| Connection form (adv. fields)  | `TablePro/Views/Connection/ConnectionFormView.swift`             |
