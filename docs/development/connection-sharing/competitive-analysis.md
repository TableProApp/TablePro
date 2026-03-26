# Competitive Analysis: Connection Sharing Across Database Clients

Research across 20+ database client tools to identify best-of-breed approaches.

---

## Feature Matrix

| Tool | Format | Creds in Export | Team Sync | Git-Friendly | CLI | Secrets Mgr |
|------|--------|----------------|-----------|-------------|-----|-------------|
| **TablePlus** | `.tableplusconnection` (proprietary) | No | None | No | URI import | No |
| **DBeaver** | JSON (`data-sources.json`) | Never (separate encrypted file) | Team Edition (paid, server) | **Yes** | No | **Vault, AWS SM, CyberArk** |
| **DataGrip** | XML (`.idea/dataSources.xml`) | Never | Settings Repository (Git) | **Yes** | No | AWS Toolkit plugin |
| **Navicat** | NCX (XML) | Optional (weak AES) | **Cloud + On-Prem Server** | No | No | No |
| **Sequel Ace** | Plist / SPF | No (Keychain only) | None | No | No | No |
| **Beekeeper Studio** | SQLite | Cloud workspaces (AES-GCM) | Team folders | No | No | No |
| **DbVisualizer** | XML (`dbvis.xml`) | No (private attributes) | **Git-backed mounted folders** | **Yes** | No | No |
| **Postico** | `.posticofavorite` | Optional (passphrase encrypt) | None | No | No | No |
| **pgAdmin** | JSON | Never | Shared servers (server mode) | Yes | **`--dump/load-servers`** | No |
| **MySQL Workbench** | Encrypted file | Auto-encrypted (one-time password) | None | No | No | No |
| **Azure Data Studio** | JSON (`settings.json`) | Manual copy | None | Yes | No | No |
| **HeidiSQL** | Text file (portable mode) | In text file | None | No | No | No |
| **MongoDB Compass** | JSON | Optional (passphrase encrypt) | None | Yes | **`--export/import`** | No |
| **RedisInsight** | JSON | Via env vars / JSON file | None | Yes | Pre-config JSON | No |
| **PopSQL** | Cloud-only | 3-tier (direct/cloud/bridge) | **Real-time collab** | No | No | OAuth/IAM |
| **Arctype** | Cloud-only | Workspace sharing | Share via link | No | No | No |
| **DbGate** | Database-backed (Team) | Cloud storage (encrypted) | **DB as settings store** | No | No | No |

---

## Best-of-Breed Ideas

### 1. Credential Separation (DBeaver) — ADOPT

**What:** Two files: `data-sources.json` (shareable, Git-safe) and `credentials-config.json` (encrypted, local-only).

**Why it's the best:** Clean, principled separation. The config file can be committed to Git without any security risk. Credentials are always a separate concern.

**For TablePro:** Export `.tablepro` JSON is always credential-free. Optional `.tablepro-secrets` companion file with AES-256-GCM encryption when user opts in.

---

### 2. Passphrase-Encrypted Export (MongoDB Compass + MySQL Workbench) — ADOPT

**What:** Compass CLI: `--export-connections --passphrase "secret"`. MySQL Workbench: auto-generates a one-time password displayed once.

**Why it's the best:** Simple, secure, no infrastructure needed. Good for "share with one colleague" scenario.

**For TablePro:** When "Include Credentials" is checked in export sheet, require a passphrase. AES-256-GCM encryption. Import prompts for passphrase.

---

### 3. Git-Backed Mounted Folders (DbVisualizer) — ADOPT

**What:** Mount a folder (local, network, Git repo) as a connection source. Everyone who mounts the same folder sees the same connections. Private credentials stay local.

**Why it's the best:** Zero new infrastructure. Leverages existing Git repos. Version history for free. Clean separation of shared config vs private secrets.

**For TablePro:** "Linked Folder" in settings. Point to a directory. TablePro watches via FSEvents, auto-imports/updates connections from `.tablepro` files found there. Team commits to shared Git repo, each dev clones and links.

---

### 4. Per-User Credentials (PopSQL) — ADOPT

**What:** Connection details (host/port/DB/SSH/SSL) shared across team. Each user enters their own password, stored only in local keychain.

**Why it's the best:** Solves the security vs convenience tradeoff. Shared config doesn't mean shared secrets.

**For TablePro:** Imported connections without credentials show a "key" badge. First connect prompts for password. Password goes to local Keychain only.

---

### 5. Copy to Clipboard as Shareable Format (DataGrip) — ADOPT

**What:** Right-click data source > "Copy to clipboard" as XML snippet. Paste in Slack/email. Recipient pastes in their IDE.

**Why it's the best:** Fastest possible sharing for ad-hoc use. No file system involved.

**For TablePro:** Right-click > "Copy as Link" generates `tablepro://import?name=...&host=...&type=...` URL. Paste anywhere. Clickable.

---

### 6. Drag-and-Drop Export (Postico) — ADOPT

**What:** Drag a favorite from sidebar to Finder = creates `.posticofavorite` file. Drag file onto app = import.

**Why it's the best:** Native macOS UX. Zero friction. Discoverable.

**For TablePro:** Drag from `WelcomeWindowView` sidebar to Finder = `.tablepro` file. Drag `.tablepro` file onto TablePro dock icon or welcome window = import.

---

### 7. CLI Export/Import (MongoDB Compass + pgAdmin) — ADOPT (Tier 3)

**What:** `compass --export-connections --output file.json`. pgAdmin: `setup.py --dump-servers servers.json`.

**Why it's the best:** Enables automation, CI/CD provisioning, onboarding scripts, Docker container setup.

**For TablePro:** `tablepro --export-connections [-o file.tablepro] [--passphrase "..."]` and `tablepro --import-connections file.tablepro [--passphrase "..."]`.

---

### 8. Environment Variable References (DBeaver) — ADOPT (Tier 2)

**What:** Use `${DB_PASSWORD}` in connection fields. Resolved at connection time from environment.

**Why it's the best:** Infrastructure-as-code pattern. Works with `.env` files, 1Password CLI (`op run`), Vault agent, AWS credential chain. No secrets in files ever.

**For TablePro:** Support `$VAR` and `${VAR}` syntax in exported connection files for password, SSH password, key passphrase, and file paths. Resolved at connection time.

---

### 9. Deploy Lockdown Mode (RedisInsight) — ADOPT (Tier 3)

**What:** Environment variable disables all connection add/edit/delete UI.

**Why it's the best:** Essential for kiosk/demo/shared-machine deployments. Simple to implement, high value for specific use cases.

**For TablePro:** `TABLEPRO_READONLY_CONNECTIONS=1` env var or `--readonly-connections` launch arg.

---

### 10. Auto-Encrypted Export (MySQL Workbench) — CONSIDER

**What:** Export always encrypted. Auto-generated password shown once in UI.

**Why it works:** Secure by default. No user decision about "should I encrypt?"

**For TablePro:** Not adopting the auto-encrypt-everything approach (too heavy for simple sharing). But adopting the one-time password display UX for when encryption IS chosen.

---

## What NOT to Adopt

| Idea | From | Why Skip |
|------|------|----------|
| Self-hosted collaboration server | Navicat On-Prem | Massive scope, enterprise-only, operational burden |
| Real-time query co-editing | PopSQL | Different product category |
| Database-as-settings-store | DbGate Team | Adds complexity, requires user to maintain a DB for their DB client |
| Cloud-hosted credentials | Beekeeper, PopSQL | Security liability, requires cloud infrastructure |
| Proprietary binary format | TablePlus | Not Git-friendly, not inspectable, not automatable |
| Weak encryption (AES-128, custom cipher) | Navicat NCX | Known broken by security researchers |
| Windows Registry storage | HeidiSQL | Not applicable to macOS |

---

## Positioning

**TablePro's unique angle:** The first macOS-native database client that treats connection configs like code — version-controlled, human-readable, Git-committable, with clean credential separation and environment variable support.

| Competitor | Their strength | TablePro's response |
|-----------|---------------|-------------------|
| DBeaver | Enterprise secrets management | Start with env var refs, add Vault/AWS later |
| DataGrip | VCS integration via `.idea/` project | Linked Folders watching any directory |
| DbVisualizer | Git-backed mounted folders | Same concept, better macOS-native UX |
| PopSQL | Real-time collaboration | Focus on async sharing (files, links, Git) |
| Navicat | Full cloud platform | Lightweight file-based approach, no server needed |
| TablePlus | Simple, fast | Match simplicity, add team sharing they lack |
