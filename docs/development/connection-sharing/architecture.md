# Technical Architecture: Connection Sharing

---

## File Format Specification

### `.tablepro` Export Format (v1)

A single JSON file containing connections and their organizational metadata. Always credential-free by default.

```json
{
  "formatVersion": 1,
  "exportedAt": "2026-03-26T10:30:00Z",
  "exportedBy": "TablePro 0.6.0",
  "connections": [
    {
      "name": "Production MySQL",
      "host": "db.example.com",
      "port": 3306,
      "database": "app_production",
      "username": "deploy",
      "type": "MySQL",
      "color": "Red",
      "tagName": "production",
      "groupName": "Backend Services",
      "safeModeLevel": "safeModeFull",
      "aiPolicy": "never",
      "sshConfig": {
        "enabled": true,
        "host": "bastion.example.com",
        "port": 22,
        "username": "deploy",
        "authMethod": "Private Key",
        "privateKeyPath": "~/.ssh/deploy_key",
        "jumpHosts": [
          {
            "host": "jump1.example.com",
            "port": 22,
            "username": "deploy",
            "authMethod": "SSH Agent"
          }
        ]
      },
      "sslConfig": {
        "mode": "Verify CA",
        "caCertificatePath": "~/certs/ca.pem"
      },
      "additionalFields": {
        "preConnectScript": "SET search_path TO app"
      },
      "startupCommands": "SET NAMES utf8mb4"
    }
  ],
  "groups": [
    {
      "name": "Backend Services",
      "color": "Blue"
    }
  ],
  "tags": [
    {
      "name": "production",
      "color": "Red",
      "isPreset": true
    }
  ],
  "sshProfiles": [
    {
      "name": "Bastion Host",
      "host": "bastion.example.com",
      "port": 22,
      "username": "deploy",
      "authMethod": "SSH Agent"
    }
  ],
  "favorites": [
    {
      "name": "Active Users Query",
      "query": "SELECT * FROM users WHERE last_login > NOW() - INTERVAL 30 DAY",
      "keyword": "active-users",
      "folderName": "Common Queries"
    }
  ],
  "favoriteFolders": [
    {
      "name": "Common Queries"
    }
  ]
}
```

### Design Decisions in the Format

1. **No UUIDs** — Connections get new UUIDs on import. References use names instead of IDs (`tagName` not `tagId`, `groupName` not `groupId`). This avoids UUID collisions and makes the file human-readable.

2. **File paths use `~`** — Paths like `~/.ssh/id_rsa` are portable across macOS users. Absolute paths (`/Users/dat/.ssh/id_rsa`) are converted to `~` form on export.

3. **`formatVersion` for forward compat** — Unknown fields are ignored by older versions. Breaking changes bump the version.

4. **Flat connection object** — SSH and SSL configs are nested objects (matching `SSHConfiguration` and `SSLConfiguration` structs), not flattened. This is cleaner than the internal `StoredConnection` format.

5. **No `sshProfileId`** — SSH config is always inlined. Profiles are exported separately for the user to set up, but connections carry their full SSH config.

### Encrypted Export Format

When user opts to include credentials:

```
┌─────────────────────────────────────┐
│ Magic bytes: "TPRO" (4 bytes)       │
│ Version: 1 (1 byte)                 │
│ Salt (32 bytes, random)             │
│ IV/Nonce (12 bytes, random)         │
│ Encrypted payload (AES-256-GCM)     │
│ Auth tag (16 bytes)                 │
└─────────────────────────────────────┘
```

- Key derivation: PBKDF2 with SHA-256, 600,000 iterations (OWASP 2023 recommendation)
- Encryption: AES-256-GCM (authenticated encryption)
- The encrypted payload is the same JSON format but with additional `credentials` section per connection:

```json
{
  "credentials": {
    "Production MySQL": {
      "password": "...",
      "sshPassword": "...",
      "keyPassphrase": "...",
      "totpSecret": "...",
      "pluginSecureFields": { "fieldId": "value" }
    }
  }
}
```

- File extension: `.tablepro` (same extension, detected by magic bytes)

---

## Data Models

### New Types

```swift
// MARK: - Export Envelope

struct ConnectionExportEnvelope: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let exportedBy: String
    var connections: [ExportableConnection]
    var groups: [ExportableGroup]
    var tags: [ExportableTag]
    var sshProfiles: [ExportableSSHProfile]
    var favorites: [ExportableFavorite]
    var favoriteFolders: [ExportableFavoriteFolder]
}

// MARK: - Exportable Connection (credential-free)

struct ExportableConnection: Codable {
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String                    // DatabaseType.rawValue
    let color: String                   // ConnectionColor.rawValue
    let tagName: String?                // Resolved from tagId
    let groupName: String?              // Resolved from groupId
    let safeModeLevel: String
    let aiPolicy: String?
    let sshConfig: SSHConfiguration     // Reuse existing type
    let sslConfig: SSLConfiguration     // Reuse existing type
    let additionalFields: [String: String]?
    let redisDatabase: Int?
    let startupCommands: String?
}

// MARK: - Import Result

struct ConnectionImportItem: Identifiable {
    let id = UUID()
    let connection: ExportableConnection
    var status: ImportStatus
    var isSelected: Bool

    enum ImportStatus {
        case ready                          // Clean import
        case needsAttention([ImportWarning]) // Has warnings
        case duplicate(existing: DatabaseConnection) // Name+host+port+type match
    }
}

enum ImportWarning {
    case sshKeyNotFound(path: String)
    case sslCertNotFound(path: String)
    case pluginNotInstalled(type: String)
    case agentSocketNotFound(path: String)
}
```

### Environment Variable Support (Tier 2)

```swift
// In exported JSON, fields can reference env vars:
// "host": "${DB_HOST}"
// "username": "$DB_USER"
// "password": "${DB_PASSWORD}"     (only in encrypted exports)
// "privateKeyPath": "${SSH_KEY}"

enum EnvVarResolver {
    static func resolve(_ value: String) -> String
    // Replaces $VAR and ${VAR} with ProcessInfo.processInfo.environment values
    // Unresolved vars left as-is (logged as warning)
}
```

---

## License Gating

| Feature | License | Gate point |
|---------|---------|------------|
| Export/import `.tablepro` files | Free | — |
| Import preview, duplicate detection | Free | — |
| Share via link, drag-and-drop | Free | — |
| UTType registration, double-click open | Free | — |
| Encrypted export (Include Credentials) | Pro | Export sheet: hide checkbox, show "Pro" badge |
| Linked Folders | Pro | Settings > Sync: show upgrade prompt |
| Environment variable resolution | Pro | Connection time: resolve vars only if licensed |
| CLI export/import | Pro | CLI args: print upgrade message and exit |
| Read-only lockdown mode | Pro | App launch: ignore env var if not licensed |
| Secrets manager integration | Pro | Connection form: hide credential source picker |

Use `LicenseManager.shared.hasFeature(.connectionSharingPro)` or equivalent. Free features require no license check.

---

## Component Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    UI Layer                                │
│                                                           │
│  WelcomeWindowView          ConnectionImportSheet         │
│  ┌─────────────────┐       ┌──────────────────────┐      │
│  │ Export button    │       │ Preview list          │      │
│  │ Import button    │       │ Status indicators     │      │
│  │ Drag source      │       │ Select/deselect       │      │
│  │ Context menu     │       │ Duplicate resolution  │      │
│  │ (Copy as Link)   │       │ Import button         │      │
│  └────────┬────────┘       └──────────┬───────────┘      │
│           │                           │                    │
├───────────┼───────────────────────────┼────────────────────┤
│           │        Service Layer      │                    │
│           ▼                           ▼                    │
│  ┌─────────────────────────────────────────────────┐      │
│  │         ConnectionExportService                  │      │
│  │                                                  │      │
│  │  exportConnections(_:includeCredentials:pass:)    │      │
│  │  importFromFile(_:passphrase:) -> ImportPreview   │      │
│  │  importConfirmed(_:) -> [DatabaseConnection]      │      │
│  │  exportToClipboardLink(_:)                        │      │
│  │  validateImportItem(_:) -> [ImportWarning]        │      │
│  └──────────┬──────────────────────┬────────────────┘      │
│             │                      │                       │
│  ┌──────────▼──────────┐  ┌───────▼─────────────────┐     │
│  │ ConnectionExport    │  │  CryptoService           │     │
│  │ Serializer          │  │  (AES-256-GCM encrypt/   │     │
│  │ (JSON encode/decode)│  │   decrypt with PBKDF2)   │     │
│  └─────────────────────┘  └─────────────────────────┘     │
│                                                            │
├────────────────────────────────────────────────────────────┤
│                    Storage Layer                           │
│                                                            │
│  ConnectionStorage ──── KeychainHelper                     │
│  GroupStorage      ──── TagStorage                         │
│  SSHProfileStorage ──── SQLFavoriteStorage                 │
│                                                            │
├────────────────────────────────────────────────────────────┤
│                    System Integration                      │
│                                                            │
│  AppDelegate+FileOpen ── UTType registration (Info.plist)  │
│  DeeplinkHandler      ── NSDraggingSource/Destination      │
│  NSPasteboard         ── FSEvents (Tier 2: Linked Folders) │
└────────────────────────────────────────────────────────────┘
```

---

## Integration Points

### 1. Export Flow

```
User selects connections in WelcomeWindowView
    → Right-click > "Export Selected..." OR toolbar button
    → NSSavePanel (.tablepro extension)
    → Optional: "Include Credentials" checkbox + passphrase field
    → ConnectionExportService.exportConnections()
        → Resolve tagId → tagName via TagStorage
        → Resolve groupId → groupName via GroupStorage
        → Inline SSH config (drop sshProfileId)
        → Convert absolute paths to ~/relative
        → Strip all Keychain secrets (unless encrypted export)
        → JSON encode → write to file
```

### 2. Import Flow

```
User triggers import (File > Import, double-click .tablepro, drag-drop)
    → AppDelegate+FileOpen routes to import handler
    → ConnectionExportService.importFromFile()
        → Detect format (JSON or encrypted via magic bytes)
        → If encrypted: prompt passphrase → decrypt
        → JSON decode → [ExportableConnection]
        → Validate each: check paths, detect duplicates, check plugins
        → Return ImportPreview
    → ConnectionImportSheet displays preview
        → User selects/deselects, resolves duplicates
    → ConnectionExportService.importConfirmed()
        → Generate new UUIDs
        → Resolve tagName → existing tag or create new
        → Resolve groupName → existing group or create new
        → ConnectionStorage.addConnection() for each
        → If encrypted export had credentials: save to Keychain
        → Trigger SyncChangeTracker for iCloud sync
```

### 3. Drag-and-Drop

```
Export (drag FROM WelcomeWindowView):
    → NSItemProvider with .fileURL promise
    → On drag start: serialize to temp .tablepro file
    → Finder receives file

Import (drag TO WelcomeWindowView or dock icon):
    → NSView accepts .tablepro UTType drops
    → Route to import flow above
```

### 4. Copy as Link

```
Right-click connection > "Copy as Link"
    → Build tablepro://import URL with all non-secret fields
    → Extended URL format (more fields than current DeeplinkHandler):
        tablepro://import?name=...&host=...&port=...&type=...
            &username=...&database=...&color=...&tag=...
            &sshHost=...&sshPort=...&sshUser=...&sshAuth=...
            &sslMode=...&safeMode=...
    → Copy to NSPasteboard
```

### 5. UTType Registration (Info.plist)

```xml
<dict>
    <key>UTTypeIdentifier</key>
    <string>com.tablepro.connections</string>
    <key>UTTypeDescription</key>
    <string>TablePro Connections</string>
    <key>UTTypeConformsTo</key>
    <array>
        <string>public.json</string>
    </array>
    <key>UTTypeTagSpecification</key>
    <dict>
        <key>public.filename-extension</key>
        <array>
            <string>tablepro</string>
        </array>
    </dict>
</dict>
```

### 6. Linked Folder (Tier 2)

```
User configures linked folder path in Settings > Sync
    → LinkedFolderWatcher starts FSEvents monitor
    → On file change/add:
        → Parse .tablepro files in directory
        → Diff against last known state
        → Add/update/remove linked connections
        → Linked connections stored separately (not in ConnectionStorage)
        → Marked as read-only, visually distinct (folder icon badge)
    → Credentials: resolved from Keychain (keyed by connection name+host)
                   OR from env vars if ${VAR} syntax used
    → On app launch: full scan of linked folder
    → On file delete: remove linked connections with confirmation
```

---

## File Locations (New Files)

| File | Purpose |
|------|---------|
| `Models/Connection/ConnectionExport.swift` | `ConnectionExportEnvelope`, `ExportableConnection`, `ImportPreview`, `ImportWarning` types |
| `Core/Services/Export/ConnectionExportService.swift` | Export/import logic, validation, duplicate detection |
| `Core/Services/Export/ConnectionExportCrypto.swift` | AES-256-GCM encryption/decryption with PBKDF2 |
| `Core/Services/Export/EnvVarResolver.swift` | Environment variable resolution (Tier 2) |
| `Core/Services/Export/LinkedFolderWatcher.swift` | FSEvents-based directory monitoring (Tier 2) |
| `Views/Connection/ConnectionImportSheet.swift` | Import preview/confirmation SwiftUI view |
| `Views/Connection/WelcomeWindowView.swift` | Modified — add export/import actions, drag source |
| `AppDelegate+FileOpen.swift` | Modified — handle `.tablepro` file opens |
| `Info.plist` | Modified — register `com.tablepro.connections` UTType |

---

## Path Portability

File paths in connections (SSH keys, SSL certs) need special handling:

### On Export
- `/Users/dat/.ssh/id_rsa` → `~/.ssh/id_rsa` (replace home dir with `~`)
- `/Users/dat/certs/ca.pem` → `~/certs/ca.pem`
- Paths outside home dir: keep absolute (e.g., `/etc/ssl/cert.pem`)

### On Import
- `~/.ssh/id_rsa` → expand `~` to current user's home dir
- Validate file exists at resolved path
- If missing: flag as `ImportWarning.sshKeyNotFound` / `.sslCertNotFound`
- Connection still imports (user can fix path later in connection form)

---

## Duplicate Detection

On import, each connection is checked against existing connections:

```
Match criteria: name + host + port + type (case-insensitive name)

If match found:
    → Show as "duplicate" in import preview
    → User options:
        1. Skip (don't import)
        2. Replace (update existing connection with imported values)
        3. Import as copy (append " (Imported)" to name)
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Corrupt JSON | Show alert: "This file is not a valid TablePro export" |
| Wrong passphrase | Show alert: "Incorrect passphrase. Please try again." (retry allowed) |
| Unsupported formatVersion | Show alert: "This file was created by a newer version of TablePro. Please update." |
| Empty file | Show alert: "This file contains no connections." |
| Partial parse (some connections valid, some not) | Import valid ones, list errors for invalid ones |
| Plugin not installed | Import connection with warning badge, unusable until plugin installed |
