---
paths:
  - "apple/TablePro/Core/**/*Storage*.swift"
  - "apple/TablePro/Core/**/*Sync*.swift"
  - "apple/TablePro/Core/Database/**/*"
  - "apple/TablePro/Core/Plugins/PluginMetadataRegistry*.swift"
  - "apple/TablePro/Core/Services/Query/**/*"
  - "apple/Packages/TableProCore/Sources/TableProSyncTransport/**/*"
  - "apple/CloudKit/**/*"
---

# Storage, sync and the database core

This path holds user data. A silent wrong answer here looks exactly like an empty database, so prove late-completion and cancellation behavior with a test.

- **A synced CKRecord type or field reaches CloudKit Production before anything writes it.** Both apps pin the container to Production, where nothing is auto-created, and CloudKit rejects a whole record that carries an undeclared field. Write fields only through `record.fields(SomeSyncField.self)`, never `record["..."]`. To ship one: add it in Development, deploy to Production in the Console, run `apple/scripts/export-cloudkit-schema.sh`, commit `apple/CloudKit/production-schema.ckdb`, then add it to the matching `verifiedInProduction`. `ProductionSchemaParityTests` checks code against the snapshot in both directions, not against the server, so never edit the snapshot by hand: `apple/scripts/export-cloudkit-schema.sh --check` compares it with Production. A tag's `app` job runs `--check-deployed` instead, which fails only on a record type, field, field type, index, role or grant the tag's snapshot has and Production lacks.
- **A storage format stays readable by the previous stable.** Sparkle never downgrades, and a beta user can turn betas off (`apple/RELEASING.md`, Storage check).
- **Persist, then notify.** `SyncChangeTracker.markDeleted()` runs after the storage write, because its notification can start a sync that re-uploads the record from the stale file.
- **Concurrent schema loads await the one in-flight `loadTask`** in `SQLSchemaProvider`; never guard with a flag that returns without data.
- **Every metadata read goes through `DatabaseManager.withMetadataDriver`**, never `MetadataConnectionPool.shared` directly, so an embedded engine with `supportsConnectionPooling = false` (DuckDB, PGlite) stays on its session driver; a second connection to it is a different, empty database.
- **A capability with no `DriverPlugin` static is curated per type**, and `buildMetadataSnapshot` must carry it over from the built-in snapshot, or plugin registration resets it to the default.

## Which store owns what

| Data | Store | Owner |
| --- | --- | --- |
| Connection passwords | Keychain | `ConnectionStorage` |
| Preferences | UserDefaults | `AppSettingsStorage`, `AppSettingsManager` |
| Editor and grid fonts | UserDefaults, device-local, never synced | `TypographySettings` through `AppSettingsManager` |
| Appearance mode (Auto, Light, Dark) | UserDefaults, device-local, never synced | `AppSettingsStorage` through `AppSettingsManager.appearanceMode` |
| Light and dark theme ids (iCloud-synced, category `appearance`) | UserDefaults | `AppearanceSettings` through `AppSettingsManager` |
| User themes (iCloud-synced, one `AppSettings` record `theme.<id>` each) | JSON, one file per theme | `ThemeCatalog` (sync rules: `.claude/rules/theme.md`, Sync) |
| Query history | SQLite FTS5 | `QueryHistoryStorage` |
| Tab state | JSON | `TabPersistenceCoordinator`, `TabDiskActor` |
| Filter defaults and presets | UserDefaults | `FilterSettingsStorage`, `FilterPresetStorage` |
| Per-table filters | JSON, one file per table | `FilterSettingsStorage` |
| Generate Rows settings per table | UserDefaults, device-local | `RowGenerationSettingsStore` |
| Favorite tables (iCloud-synced) | UserDefaults | `FavoriteTablesStorage` |
| Sidebar database and schema filters, recent tables | UserDefaults, device-local | `DatabaseTreeFilterStorage`, `RecentTablesStore` |
| History drawer state | UserDefaults, device-local | `HistoryPanelPreferencesStorage` |
| Server Dashboard tiles, per connection | UserDefaults, device-local | `ServerDashboardTileStorage` |
| Trusted external links (loopback only) | UserDefaults | `ExternalConnectionTrustStore` |
| Table load timings (no identifying data, never uploaded) | JSON lines | `TableLoadHistoryStore` |
| Reopen Last Session list (`LastSession.json`, plus `LastOpenConnections.json` holding only the ids that reconnect, which older builds read) | JSON | `LastOpenConnectionsStorage` |
