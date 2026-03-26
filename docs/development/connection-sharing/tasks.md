# Task Tracking: Connection Sharing & Alternative Sync

**Legend:**
`[ ]` Not started | `[~]` In progress | `[x]` Done | `[-]` Blocked | `[s]` Skipped

---

## Tier 1: Manual Export/Import (MVP)

### 1.1 Data Models & Export Format (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.1.1 | Define `ConnectionExportEnvelope` and `ExportableConnection` types in `Models/Connection/ConnectionExport.swift` | [ ] | S | — | Codable structs, see architecture.md for schema |
| 1.1.2 | Define `ExportableGroup`, `ExportableTag`, `ExportableSSHProfile` types | [ ] | S | — | Minimal: name + color, no UUIDs |
| 1.1.3 | Define `ExportableFavorite`, `ExportableFavoriteFolder` types | [ ] | S | — | Name, query, keyword, folder ref by name |
| 1.1.4 | Define `ImportPreview`, `ConnectionImportItem`, `ImportStatus`, `ImportWarning` types | [ ] | S | — | Used by import sheet UI |
| 1.1.5 | Add `DatabaseConnection.toExportable()` method | [ ] | S | 1.1.1 | Resolve tagId→tagName, groupId→groupName, inline SSH, convert paths to `~/` |
| 1.1.6 | Add `ExportableConnection.toDatabaseConnection()` method | [ ] | M | 1.1.1 | Generate new UUID, expand `~/` paths, leave password nil |
| 1.1.7 | Write unit tests for export/import round-trip | [ ] | M | 1.1.5, 1.1.6 | Test all field types, path conversion, tag/group resolution |

### 1.2 Export Service (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.2.1 | Create `ConnectionExportService` in `Core/Services/Export/` | [ ] | M | 1.1.* | Singleton service, handles export and import logic |
| 1.2.2 | Implement `exportConnections(_:to:)` — serialize and write JSON | [ ] | M | 1.2.1 | Pretty-printed, sorted keys, UTF-8 |
| 1.2.3 | Implement `importFromFile(_:) -> ImportPreview` — parse and validate | [ ] | M | 1.2.1 | Detect format, decode JSON, validate paths, detect duplicates |
| 1.2.4 | Implement `importConfirmed(_:) -> [DatabaseConnection]` — commit import | [ ] | M | 1.2.3 | Create UUIDs, resolve tags/groups, add via ConnectionStorage |
| 1.2.5 | Implement duplicate detection logic (name+host+port+type match) | [ ] | S | 1.2.3 | Case-insensitive name comparison |
| 1.2.6 | Implement path validation (check SSH key, SSL cert existence) | [ ] | S | 1.2.3 | FileManager.fileExists for expanded `~/` paths |
| 1.2.7 | Implement plugin availability check | [ ] | S | 1.2.3 | PluginMetadataRegistry.shared.hasType() |
| 1.2.8 | Implement tag/group resolution (match by name, create if missing) | [ ] | S | 1.2.4 | Use TagStorage, GroupStorage |
| 1.2.9 | Write unit tests for export service | [ ] | M | 1.2.2-1.2.8 | Mock storage, test duplicate detection, tag resolution |

### 1.3 Encrypted Export (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.3.1 | Create `ConnectionExportCrypto` in `Core/Services/Export/` | [ ] | M | — | AES-256-GCM via CryptoKit, PBKDF2 key derivation |
| 1.3.2 | Implement `encrypt(data:passphrase:) -> Data` with TPRO header | [ ] | M | 1.3.1 | Magic bytes + salt + nonce + ciphertext + tag |
| 1.3.3 | Implement `decrypt(data:passphrase:) -> Data` | [ ] | M | 1.3.1 | Detect magic bytes, extract components, decrypt |
| 1.3.4 | Implement `isEncrypted(_:) -> Bool` detection via magic bytes | [ ] | S | 1.3.1 | Check first 4 bytes = "TPRO" |
| 1.3.5 | Extend export service: collect Keychain credentials for selected connections | [ ] | M | 1.2.2, 1.3.2 | Load all 5 secret types per connection from Keychain |
| 1.3.6 | Extend import service: decrypt and restore credentials to Keychain | [ ] | M | 1.2.4, 1.3.3 | Save to Keychain using new connection UUIDs |
| 1.3.7 | Write unit tests for crypto round-trip | [ ] | S | 1.3.2, 1.3.3 | Test encrypt/decrypt, wrong passphrase, corrupt data |

### 1.4 Import Sheet UI (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.4.1 | Create `ConnectionImportSheet` SwiftUI view | [ ] | L | 1.2.3 | Sheet presented from WelcomeWindowView |
| 1.4.2 | Connection list with status badges (green/yellow/orange) | [ ] | M | 1.4.1 | Use ImportPreview data |
| 1.4.3 | Select/deselect checkboxes per connection | [ ] | S | 1.4.1 | Toggle isSelected |
| 1.4.4 | Expandable warning details per connection | [ ] | S | 1.4.1 | DisclosureGroup with warning messages |
| 1.4.5 | Duplicate resolution picker (Skip/Replace/Import as Copy) | [ ] | M | 1.4.1 | Picker per duplicate item |
| 1.4.6 | Passphrase prompt for encrypted files | [ ] | S | 1.3.4 | SecureField, retry on failure |
| 1.4.7 | Summary footer (X connections, Y warnings, Z duplicates) | [ ] | S | 1.4.1 | Computed from preview data |
| 1.4.8 | Import/Cancel buttons with progress indicator | [ ] | S | 1.4.1 | Disable Import until at least one selected |

### 1.5 Export UI Integration (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.5.1 | Add "Export Selected..." to WelcomeWindowView context menu | [ ] | S | 1.2.2 | Right-click on selected connection(s) |
| 1.5.2 | Add "Export Connections..." to File menu / toolbar | [ ] | S | 1.2.2 | Opens NSSavePanel |
| 1.5.3 | Add "Import Connections..." to File menu / toolbar | [ ] | S | 1.4.1 | Opens NSOpenPanel filtered to .tablepro |
| 1.5.4 | Export options sheet: include credentials checkbox + passphrase fields | [ ] | S | 1.3.5 | Shown before NSSavePanel |
| 1.5.5 | Add "Include Favorites" checkbox to export options | [ ] | S | 1.5.4 | Default: unchecked |

### 1.6 macOS System Integration (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 1.6.1 | Register `com.tablepro.connections` UTType in Info.plist | [ ] | S | — | Conforms to public.json, extension: .tablepro |
| 1.6.2 | Handle `.tablepro` file open in AppDelegate+FileOpen | [ ] | M | 1.2.3, 1.4.1 | Route to import sheet |
| 1.6.3 | Implement drag-from-sidebar export (NSItemProvider with .fileURL) | [ ] | M | 1.2.2 | Write temp .tablepro file on drag start |
| 1.6.4 | Implement drag-to-sidebar import (NSView drop target) | [ ] | M | 1.6.2 | Accept .tablepro UTType drops |
| 1.6.5 | Implement "Copy as Link" context menu action | [ ] | M | — | Build extended tablepro://import URL, copy to pasteboard |
| 1.6.6 | Extend DeeplinkHandler.parseImport() for new URL parameters | [ ] | S | 1.6.5 | Add sshHost, sshPort, sshUser, sslMode, color, tag, safeMode |
| 1.6.7 | Register document icon for .tablepro files | [ ] | S | 1.6.1 | Add icon asset to Asset Catalog |
| 1.6.8 | Write integration tests for file open and deeplink handling | [ ] | M | 1.6.2, 1.6.6 | Test AppDelegate routing |

---

## Tier 2: Team Sharing

### 2.1 Linked Folders (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 2.1.1 | Design linked folder data model and settings storage | [ ] | S | — | Array of folder paths in SyncSettings |
| 2.1.2 | Add linked folder configuration UI in Settings > Sync | [ ] | M | 2.1.1 | Folder picker, add/remove, enable/disable per folder |
| 2.1.3 | Create `LinkedFolderWatcher` service using FSEvents/DispatchSource | [ ] | L | 2.1.1 | Watch configured directories for .tablepro file changes |
| 2.1.4 | Implement full scan on app launch | [ ] | M | 2.1.3 | Recursively find all .tablepro files, parse, present |
| 2.1.5 | Implement incremental updates on file change events | [ ] | M | 2.1.3 | Diff against previous state, add/update/remove connections |
| 2.1.6 | Create `LinkedConnectionStorage` (separate from ConnectionStorage) | [ ] | M | 2.1.4 | In-memory store for linked connections, not persisted to UserDefaults |
| 2.1.7 | Integrate linked connections into WelcomeWindowView sidebar | [ ] | M | 2.1.6 | Separate section, folder badge, "Linked" label |
| 2.1.8 | Make linked connections read-only in connection form | [ ] | S | 2.1.7 | Disable edit fields, show "Open source file" button |
| 2.1.9 | Per-user Keychain credential lookup for linked connections | [ ] | M | 2.1.6 | Key by name+host (not UUID since UUIDs are generated) |
| 2.1.10 | Handle file deletion: remove linked connections with notification | [ ] | S | 2.1.5 | Show notification, no confirmation needed |
| 2.1.11 | Handle malformed files: log error, skip, don't affect other files | [ ] | S | 2.1.4 | OSLog warning |
| 2.1.12 | Write tests for LinkedFolderWatcher | [ ] | M | 2.1.3-2.1.5 | Mock FSEvents, test add/update/remove lifecycle |

### 2.2 Environment Variable References (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 2.2.1 | Create `EnvVarResolver` utility in `Core/Services/Export/` | [ ] | S | — | Regex-based $VAR and ${VAR} replacement |
| 2.2.2 | Integrate env var resolution in connection flow (DatabaseManager.connect) | [ ] | M | 2.2.1 | Resolve just before connecting, not on import |
| 2.2.3 | Show resolved values as placeholder text in connection form | [ ] | S | 2.2.1 | Non-editable, gray text showing resolved value |
| 2.2.4 | Show warning when env var is unresolved | [ ] | S | 2.2.1 | Red badge on connection, tooltip with var name |
| 2.2.5 | Export option: convert known values to env var references | [ ] | M | 2.2.1 | Detect common patterns, suggest ${VAR} replacements |
| 2.2.6 | Write tests for env var resolution | [ ] | S | 2.2.1 | Test $VAR, ${VAR}, nested, unresolved, empty |

### 2.3 Favorites Sharing (Free export, Pro linked folders)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 2.3.1 | Add favorites and folders to export envelope | [ ] | S | 1.1.3 | Include in ConnectionExportEnvelope |
| 2.3.2 | Implement favorites export (serialize from SQLFavoriteStorage) | [ ] | M | 2.3.1 | Connection-scoped: reference connection by name |
| 2.3.3 | Implement favorites import (deserialize to SQLFavoriteStorage) | [ ] | M | 2.3.1 | Create folders first, then favorites with folder references |
| 2.3.4 | Favorite duplicate detection (name + query content) | [ ] | S | 2.3.3 | Skip duplicates |
| 2.3.5 | Write tests for favorites export/import | [ ] | S | 2.3.2, 2.3.3 | Round-trip, duplicate detection |

---

## Tier 3: Automation & Enterprise

### 3.1 CLI Export/Import (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 3.1.1 | Add `--export-connections` argument handling to app launch | [ ] | M | Tier 1 | Parse args in AppDelegate or main |
| 3.1.2 | Implement CLI export with filters (--names, --group) | [ ] | M | 3.1.1 | Reuse ConnectionExportService |
| 3.1.3 | Add `--import-connections` argument handling | [ ] | M | Tier 1 | Non-interactive: skip duplicates by default |
| 3.1.4 | Add `--passphrase` flag for encrypted operations | [ ] | S | 3.1.1 | Read from arg or stdin |
| 3.1.5 | Add `--json` output mode for machine-readable results | [ ] | S | 3.1.1 | JSON summary of import/export result |
| 3.1.6 | Add `--replace` flag for overwriting duplicates on import | [ ] | S | 3.1.3 | Alternative to default skip behavior |
| 3.1.7 | Define exit codes (0/1/2/3) and document in --help | [ ] | S | 3.1.1 | 0=success, 1=parse error, 2=passphrase, 3=partial |
| 3.1.8 | Write integration tests for CLI operations | [ ] | M | 3.1.2, 3.1.3 | Test all flags and exit codes |

### 3.2 Clipboard Auto-Detection (Free)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 3.2.1 | Detect database URIs on NSPasteboard when WelcomeWindowView gains focus | [ ] | M | — | Check for mysql://, postgresql://, etc. |
| 3.2.2 | Show non-intrusive toast/banner offering import | [ ] | S | 3.2.1 | Dismiss hides for that clipboard content |
| 3.2.3 | Route detected URI through ConnectionURLParser | [ ] | S | 3.2.1 | Reuse existing parser |
| 3.2.4 | Add toggle in Settings > General to disable | [ ] | S | 3.2.1 | Default: enabled |

### 3.3 Read-Only Lockdown Mode (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 3.3.1 | Check `TABLEPRO_READONLY_CONNECTIONS` env var on launch | [ ] | S | — | Store as app-wide flag |
| 3.3.2 | Hide New/Edit/Delete connection buttons when locked | [ ] | S | 3.3.1 | Conditional in WelcomeWindowView |
| 3.3.3 | Show lock indicator in UI | [ ] | S | 3.3.1 | Small lock icon in toolbar |
| 3.3.4 | Allow linked folder connections to still update from files | [ ] | S | 3.3.1, 2.1.* | Read-only applies to manual edits only |

### 3.4 Secrets Manager Integration (Pro)

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| 3.4.1 | Define `CredentialSource` enum (manual, envVar, onePassword, vault, awsSM) | [ ] | S | — | Add to DatabaseConnection model |
| 3.4.2 | Add "Credential Source" picker to connection form | [ ] | M | 3.4.1 | Show source-specific config fields |
| 3.4.3 | Implement 1Password CLI integration (`op read`) | [ ] | L | 3.4.1 | Shell out to `op`, parse JSON response |
| 3.4.4 | Implement HashiCorp Vault HTTP API integration | [ ] | L | 3.4.1 | KV v2 secret read, VAULT_ADDR + VAULT_TOKEN |
| 3.4.5 | Implement AWS Secrets Manager integration | [ ] | L | 3.4.1 | AWS SDK or HTTP API with SigV4 |
| 3.4.6 | Session-level credential caching | [ ] | M | 3.4.3-3.4.5 | Cache until disconnect, re-fetch on reconnect |
| 3.4.7 | Write tests with mock secrets providers | [ ] | M | 3.4.3-3.4.5 | Mock HTTP/CLI responses |

---

## Cross-Cutting Tasks

| # | Task | Status | Estimate | Dependencies | Notes |
|---|------|--------|----------|-------------|-------|
| X.0 | Add license gate checks for Pro features (encrypted export, linked folders, env vars, CLI, lockdown) | [ ] | M | — | Check `LicenseManager` for `.connectionSharing` or similar feature flag |
| X.1 | Update CHANGELOG.md with new features | [ ] | S | Per tier | Under [Unreleased] > Added |
| X.2 | Add localization strings for all new UI | [ ] | M | Per tier | String(localized:) for alerts, buttons, labels |
| X.3 | Update docs/features/ with connection sharing guide | [ ] | M | Tier 1 | New page: docs/features/connection-sharing.mdx |
| X.4 | Update docs/vi/ with Vietnamese translation | [ ] | M | X.3 | Mirror English docs |
| X.5 | Add keyboard shortcuts for export/import | [ ] | S | 1.5.* | Cmd+Shift+E (export), Cmd+Shift+I (import) |
| X.6 | Analytics events for export/import usage | [ ] | S | Per tier | Track export count, import count, linked folder enable |

---

## Estimation Key

| Size | Meaning | Approximate Effort |
|------|---------|-------------------|
| S | Small | < 2 hours |
| M | Medium | 2-6 hours |
| L | Large | 6-16 hours |
| XL | Extra Large | 16+ hours |
