---
paths:
  - "TablePro/Core/**/*Storage*.swift"
  - "TablePro/Core/**/*Sync*.swift"
  - "TablePro/Core/Database/**/*"
  - "TablePro/Core/Plugins/PluginMetadataRegistry*.swift"
  - "TablePro/Core/Services/Query/**/*"
  - "Packages/TableProCore/Sources/TableProSyncTransport/**/*"
  - "CloudKit/**/*"
---

# Storage, sync and the database core

This path holds user data. A silent wrong answer here looks exactly like an empty database, so prove late-completion and cancellation behavior with a test.

- **A synced CKRecord type or field reaches CloudKit Production before anything writes it.** Both apps pin the container to Production, where nothing is auto-created, and CloudKit rejects a whole record that carries an undeclared field. Write fields only through `record.fields(SomeSyncField.self)`, never `record["..."]`. To ship one: add it in Development, deploy to Production in the Console, run `scripts/export-cloudkit-schema.sh`, commit `CloudKit/production-schema.ckdb`, then add it to the matching `verifiedInProduction`. `ProductionSchemaParityTests` checks both directions.
- **Persist, then notify.** `SyncChangeTracker.markDeleted()` runs after the storage write, because its notification can start a sync that re-uploads the record from the stale file.
- **Concurrent schema loads await the one in-flight `loadTask`** in `SQLSchemaProvider`; never guard with a flag that returns without data.
- **Every metadata read goes through `DatabaseManager.withMetadataDriver`**, never `MetadataConnectionPool.shared` directly, so an embedded engine with `supportsConnectionPooling = false` (DuckDB, PGlite) stays on its session driver; a second connection to it is a different, empty database.
- **A capability with no `DriverPlugin` static is curated per type**, and `buildMetadataSnapshot` must carry it over from the built-in snapshot, or plugin registration resets it to the default.

## Which store owns what

| Data | Store | Owner |
| --- | --- | --- |
| Connection passwords | Keychain | `ConnectionStorage` |
| Preferences | UserDefaults | `AppSettingsStorage`, `AppSettingsManager` |
| Query history | SQLite FTS5 | `QueryHistoryStorage` |
| Tab state | JSON | `TabPersistenceCoordinator`, `TabDiskActor` |
| Filter defaults and presets | UserDefaults | `FilterSettingsStorage`, `FilterPresetStorage` |
| Per-table filters | JSON, one file per table | `FilterSettingsStorage` |
| Favorite tables (iCloud-synced) | UserDefaults | `FavoriteTablesStorage` |
| Sidebar database filter, recent tables | UserDefaults, device-local | `DatabaseTreeFilterStorage`, `RecentTablesStore` |
| History drawer state | UserDefaults, device-local | `HistoryPanelPreferencesStorage` |
| Trusted external links (loopback only) | UserDefaults | `ExternalConnectionTrustStore` |
| Table load timings (no identifying data, never uploaded) | JSON lines | `TableLoadHistoryStore` |
