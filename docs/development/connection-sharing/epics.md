# Epics: Connection Sharing & Alternative Sync

## Licensing

| Epic | License |
|------|---------|
| 1.1 Export to file | Free |
| 1.2 Import from file | Free |
| 1.3 Encrypted export with credentials | **Pro** |
| 1.4 macOS integration (UTType, drag-drop, copy-as-link) | Free |
| 2.1 Linked Folders | **Pro** |
| 2.2 Environment variable references | **Pro** |
| 2.3 SQL Favorites sharing | Free (export), **Pro** (linked folders) |
| 3.1 CLI export/import | **Pro** |
| 3.2 Clipboard auto-detection | Free |
| 3.3 Read-only lockdown mode | **Pro** |
| 3.4 Secrets manager integration | **Pro** |

---

## Tier 1: Manual Export/Import (MVP)

### Epic 1.1: Export Connections to File (Free)

**Goal:** Users can select connections and export them to a `.tablepro` JSON file.

**Acceptance Criteria:**
- [ ] User can select one or multiple connections in WelcomeWindowView
- [ ] Right-click context menu shows "Export Selected Connections..."
- [ ] Toolbar/menu bar has "Export Connections..." action
- [ ] NSSavePanel opens with `.tablepro` default extension
- [ ] Export includes: connection config, SSH config (inlined), SSL config, color, safe mode, AI policy, additional fields, startup commands
- [ ] Export includes referenced groups (by name), tags (by name), SSH profiles (by config)
- [ ] Export EXCLUDES all Keychain secrets (passwords, passphrases, TOTP secrets)
- [ ] File paths converted to `~/` relative form
- [ ] sshProfileId dropped (SSH config inlined instead)
- [ ] UUIDs not included (regenerated on import)
- [ ] Exported JSON is human-readable (pretty-printed, sorted keys)
- [ ] File size < 1KB per connection typical

**User Stories:** US-1, US-9

---

### Epic 1.2: Import Connections from File (Free)

**Goal:** Users can import connections from a `.tablepro` file with preview, validation, and duplicate handling.

**Acceptance Criteria:**
- [ ] File > Import Connections... opens file picker filtered to `.tablepro`
- [ ] Import preview sheet shows all connections with status badges:
  - Green checkmark: ready to import
  - Yellow warning: needs attention (missing SSH key, SSL cert, or plugin)
  - Orange duplicate: matches existing connection (name+host+port+type)
- [ ] Each connection can be individually selected/deselected
- [ ] Duplicate resolution options per connection: Skip / Replace / Import as Copy
- [ ] Warning details expandable (which paths are missing, which plugins needed)
- [ ] On confirm: new UUIDs generated for each imported connection
- [ ] Tags resolved by name (existing tag matched, or new tag created with exported color)
- [ ] Groups resolved by name (existing group matched, or new group created)
- [ ] `~` paths expanded to current user's home directory
- [ ] Imported connections appear in WelcomeWindowView immediately
- [ ] iCloud sync triggered for imported connections (via SyncChangeTracker)
- [ ] Passwords left empty — user fills in via normal connection form

**User Stories:** US-2, US-3, US-4, US-10

---

### Epic 1.3: Encrypted Export with Credentials (Pro)

**Goal:** Pro users can optionally include credentials in an encrypted export file.

**Acceptance Criteria:**
- [ ] Export sheet has "Include Credentials" checkbox (default: unchecked)
- [ ] When checked, passphrase field appears (required, minimum 8 characters)
- [ ] Passphrase confirmation field (must match)
- [ ] File encrypted with AES-256-GCM, key derived via PBKDF2-SHA256 (600K iterations)
- [ ] Encrypted file has `TPRO` magic bytes header (distinguishable from plain JSON)
- [ ] Includes all Keychain secrets: DB password, SSH password, key passphrase, TOTP secret, plugin secure fields
- [ ] On import: auto-detect encrypted format, prompt for passphrase
- [ ] Wrong passphrase shows clear error with retry option
- [ ] Decrypted credentials saved to local Keychain on import

**User Stories:** US-5

---

### Epic 1.4: macOS Integration (UTType, Drag-Drop, Clipboard) (Free)

**Goal:** Native macOS UX for sharing connections.

**Acceptance Criteria:**
- [ ] `.tablepro` UTType registered in Info.plist (`com.tablepro.connections`, conforms to `public.json`)
- [ ] Double-clicking `.tablepro` file in Finder opens TablePro and shows import sheet
- [ ] Dragging connection(s) from WelcomeWindowView to Finder creates `.tablepro` file
- [ ] Dragging `.tablepro` file onto TablePro dock icon triggers import
- [ ] Dragging `.tablepro` file onto WelcomeWindowView triggers import
- [ ] Right-click connection > "Copy as Link" copies `tablepro://import?...` URL to clipboard
- [ ] Enhanced deeplink URL includes: name, host, port, type, username, database, color, tag, sshHost, sshPort, sshUser, sshAuth, sslMode, safeMode
- [ ] Existing `DeeplinkHandler.parseImport()` extended to handle new parameters
- [ ] `.tablepro` files show TablePro icon in Finder (document icon registered)
- [ ] QuickLook preview for `.tablepro` files showing connection summary (stretch goal)

**User Stories:** US-6, US-7, US-8

---

## Tier 2: Team Sharing

### Epic 2.1: Linked Folders (Pro)

**Goal:** TablePro watches a user-configured directory for `.tablepro` files and auto-syncs connections from them.

**Acceptance Criteria:**
- [ ] Settings > Sync has "Linked Folder" section with folder picker
- [ ] Multiple linked folders supported (e.g., one per team/project)
- [ ] FSEvents-based monitoring detects file add/change/delete
- [ ] Full scan on app launch
- [ ] `.tablepro` files in folder parsed and connections presented in sidebar
- [ ] Linked connections visually distinct (folder badge, "Linked" label, grouped separately)
- [ ] Linked connections are read-only in UI (edit opens the source file in default editor)
- [ ] Deleting a linked connection only removes it locally (doesn't delete the file)
- [ ] File deletion removes linked connections (with notification, no confirmation needed)
- [ ] Per-user credentials: Keychain lookup by connection name+host, prompt on first connect
- [ ] Subdirectory scanning (recursive `.tablepro` file discovery)
- [ ] Nested folders map to connection groups
- [ ] Error handling: invalid files logged, other files unaffected

**User Stories:** US-11, US-12, US-14, US-15

---

### Epic 2.2: Environment Variable References (Pro)

**Goal:** Exported connection files can reference environment variables for credentials and paths.

**Acceptance Criteria:**
- [ ] `$VAR` and `${VAR}` syntax recognized in any string field
- [ ] Resolution happens at connection time (not at import time)
- [ ] Unresolved variables: show warning in connection form, block connection attempt
- [ ] Supported fields: host, port (as string), username, database, password (encrypted export), sshConfig.host/username/privateKeyPath, sslConfig paths, additionalFields values
- [ ] Works with 1Password CLI: `op run -- open /path/to/TablePro.app` injects env vars
- [ ] Works with direnv, .env files (via shell profile), Vault agent
- [ ] Connection form shows resolved values in placeholder text (not editable)
- [ ] Export option: "Use environment variables" converts known values to `${VAR}` references

**User Stories:** US-13

---

### Epic 2.3: SQL Favorites Sharing

**Goal:** Exported files can include saved SQL queries and favorite folders.

**Acceptance Criteria:**
- [ ] Export envelope includes `favorites` and `favoriteFolders` arrays
- [ ] Favorites include: name, query, keyword, folder reference (by name)
- [ ] Connection-scoped favorites reference connection by name (not UUID)
- [ ] Global favorites (no connectionId) exported as-is
- [ ] On import: favorites added to SQLFavoriteStorage
- [ ] Duplicate detection by name + query content
- [ ] Folders created if not existing

**User Stories:** US-9 (extended)

---

## Tier 3: Automation & Enterprise

### Epic 3.1: CLI Export/Import (Pro)

**Goal:** Export and import connections via command line for automation.

**Acceptance Criteria:**
- [ ] `tablepro --export-connections -o file.tablepro` exports all connections
- [ ] `tablepro --export-connections --names "Prod MySQL,Staging PG" -o file.tablepro` exports selected
- [ ] `tablepro --export-connections --group "Backend" -o file.tablepro` exports by group
- [ ] `tablepro --export-connections --passphrase "..." -o file.tablepro` includes encrypted credentials
- [ ] `tablepro --import-connections file.tablepro` imports (non-interactive, skip duplicates)
- [ ] `tablepro --import-connections file.tablepro --passphrase "..."` decrypts and imports
- [ ] `tablepro --import-connections file.tablepro --replace` overwrites duplicates
- [ ] Exit codes: 0 success, 1 parse error, 2 passphrase error, 3 partial import
- [ ] JSON output mode: `--json` flag for machine-readable output
- [ ] Works in headless mode (no GUI required)

**User Stories:** US-16

---

### Epic 3.2: Clipboard Auto-Detection (Free)

**Goal:** TablePro detects database URIs on clipboard and offers to import.

**Acceptance Criteria:**
- [ ] On WelcomeWindowView focus: check NSPasteboard for database URI patterns
- [ ] Recognized patterns: `mysql://`, `postgresql://`, `mongodb://`, `redis://`, `tablepro://import`
- [ ] Show non-intrusive toast/banner: "Database connection detected on clipboard. Import?"
- [ ] Click imports via existing `ConnectionURLParser`
- [ ] Dismiss hides for that clipboard content (don't re-prompt)
- [ ] Can be disabled in Settings > General

**User Stories:** US-17

---

### Epic 3.3: Read-Only Lockdown Mode (Pro)

**Goal:** Administrators can lock down connection management for shared deployments.

**Acceptance Criteria:**
- [ ] `TABLEPRO_READONLY_CONNECTIONS=1` environment variable
- [ ] When set: hide New/Edit/Delete connection buttons
- [ ] Import still works (admin can pre-load connections)
- [ ] Connections from linked folders still update from files
- [ ] Visual indicator in UI that connections are locked
- [ ] Startup commands and safe mode levels cannot be changed

**User Stories:** US-18

---

### Epic 3.4: Secrets Manager Integration (Pro)

**Goal:** Credentials resolved from external secrets managers at connection time.

**Acceptance Criteria:**
- [ ] Connection form has "Credential Source" picker: Manual / Environment Variable / 1Password / Vault / AWS Secrets Manager
- [ ] 1Password: use `op` CLI to read items (requires 1Password CLI installed)
- [ ] Vault: HTTP API to read secrets (requires VAULT_ADDR + VAULT_TOKEN env vars)
- [ ] AWS SM: use AWS SDK to read secrets (requires AWS credentials configured)
- [ ] Credential fetched fresh on each connection attempt (respects rotation)
- [ ] Cached for session duration (avoid repeated fetches during reconnects)
- [ ] Clear error messages when secrets manager unavailable

**User Stories:** US-19
