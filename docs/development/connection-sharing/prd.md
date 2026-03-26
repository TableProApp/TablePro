# PRD: Connection Sharing & Alternative Sync

**Issue:** [#466](https://github.com/TableProApp/TablePro/issues/466)
**Status:** Planning
**Priority:** High
**Owner:** TBD

---

## Problem Statement

TablePro's iCloud sync works for a single user across their own devices, but there is no way to share connection configurations with team members. When a new developer joins a team, they must manually recreate every database connection — host, port, SSH tunnel config, SSL certificates, safe mode levels, and more. This is time-consuming, error-prone, and doesn't scale.

### Pain Points

1. **Onboarding friction** — New team members spend 30-60 minutes manually setting up 10-20 connections
2. **Configuration drift** — Connection settings diverge across team members (wrong ports, missing SSH configs, inconsistent safe mode levels)
3. **No source of truth** — No central, version-controlled place for team connection configs
4. **No sharing without workarounds** — Teams resort to sharing screenshots, Slack messages, or sticky notes with connection details
5. **Existing deeplink import is too limited** — `tablepro://import` only handles 6 of 25+ connection fields

### Who Is Affected

- **Development teams** sharing database connections for dev/staging/production environments
- **Database administrators** provisioning connections for their team
- **Consultants/freelancers** setting up connections on multiple client machines
- **DevOps engineers** who want to manage connection configs as infrastructure-as-code

---

## Goals

### Primary Goals

1. Enable users to export connection configurations (without credentials) to a portable file
2. Enable users to import connections from a file with preview, validation, and duplicate detection
3. Make the export format human-readable, Git-friendly, and version-controllable
4. Support macOS-native UX patterns (drag-and-drop, UTType registration, clipboard)

### Secondary Goals

5. Enable automatic sync from a shared directory (Git repo, network drive, Dropbox)
6. Support environment variable references for credentials and file paths
7. Provide CLI export/import for automation and provisioning workflows

### Non-Goals (Explicitly Out of Scope)

- Real-time collaborative editing (PopSQL-style)
- Self-hosted collaboration server (Navicat On-Prem-style)
- CloudKit shared database (would require team/permission model)
- Credential sync between team members (security risk; each user should have own credentials)

---

## Free vs Pro

| Feature | Free | Pro |
|---------|------|-----|
| Export/import `.tablepro` files | Yes | Yes |
| Share via link (Copy as Link) | Yes | Yes |
| Drag and drop export/import | Yes | Yes |
| Double-click `.tablepro` to import | Yes | Yes |
| Import preview with duplicate detection | Yes | Yes |
| Encrypted export with credentials | -- | Yes |
| Linked Folders (auto-sync from directory) | -- | Yes |
| Environment variable references | -- | Yes |
| CLI export/import | -- | Yes |
| Read-only lockdown mode | -- | Yes |
| Secrets manager integration | -- | Yes |

**Rationale:** Basic export/import is free to maximize adoption. When someone shares a `.tablepro` file, the recipient downloads TablePro to open it -- gating this behind Pro kills that viral loop. Power-user and team features (encryption, auto-sync, env vars, CLI) justify Pro.

---

## User Stories

### Tier 1: Manual Export/Import

| ID | Story | Priority |
|----|-------|----------|
| US-1 | As a DBA, I want to export selected connections to a file so I can share them with my team | P0 |
| US-2 | As a developer, I want to import connections from a file so I can quickly set up my environment | P0 |
| US-3 | As a user, I want to see a preview of connections before importing so I can choose which ones to add | P0 |
| US-4 | As a user, I want duplicate connections detected on import so I don't end up with duplicates | P0 |
| US-5 | As a user, I want to optionally include encrypted credentials in the export for trusted sharing | P1 |
| US-6 | As a user, I want to drag a connection to Finder to export it, and drag a file to TablePro to import it | P1 |
| US-7 | As a user, I want to right-click a connection and "Copy as Link" to share via chat/email | P1 |
| US-8 | As a user, I want to double-click a `.tablepro` file to open TablePro and start import | P1 |
| US-9 | As a user, I want exported files to include my groups, tags, and SSH profiles so the organization is preserved | P1 |
| US-10 | As a user, I want to see warnings when imported connections reference SSH keys or SSL certs that don't exist on my machine | P1 |

### Tier 2: Team Sharing

| ID | Story | Priority |
|----|-------|----------|
| US-11 | As a team lead, I want to point TablePro at a shared folder so my team's connections stay in sync | P1 |
| US-12 | As a DevOps engineer, I want to commit connection configs to Git and have TablePro auto-detect changes | P1 |
| US-13 | As a developer, I want to use `$DB_PASSWORD` in shared configs so credentials come from my local environment | P1 |
| US-14 | As a user, I want linked-folder connections to be visually distinct from my personal connections | P2 |
| US-15 | As a user, I want linked-folder connections to be read-only (edits go to the file, not local storage) | P2 |

### Tier 3: Automation & Enterprise

| ID | Story | Priority |
|----|-------|----------|
| US-16 | As a DevOps engineer, I want to export/import connections via CLI for scripting | P2 |
| US-17 | As a user, I want TablePro to auto-detect database URIs on my clipboard and offer to import | P3 |
| US-18 | As an admin, I want to lock down connection management via env var for shared deployments | P3 |
| US-19 | As an enterprise user, I want to pull credentials from 1Password/Vault/AWS Secrets Manager | P3 |

---

## Success Metrics

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Export/import adoption | >20% of multi-connection users use export within 3 months | Analytics event on export/import |
| Onboarding time reduction | <5 min to set up all connections from file (vs 30-60 min manual) | User feedback |
| Linked folder adoption | >5% of Pro users enable linked folders within 6 months | Settings telemetry |
| Support ticket reduction | Fewer "how do I share connections" questions | Support metrics |

---

## Security Requirements

1. **Credentials MUST NOT appear in export files by default** — Keychain secrets (DB password, SSH password, key passphrase, TOTP secret, plugin secure fields) are always excluded unless user explicitly opts in
2. **When credentials are included, the file MUST be encrypted** — AES-256-GCM with user-provided passphrase
3. **Import MUST prompt for confirmation** — Never silently add connections
4. **Machine-specific paths MUST be flagged** — SSH key paths, SSL cert paths that don't exist on the target machine get a warning badge
5. **Environment variable references MUST be resolved at connection time only** — Never persist resolved values

---

## Constraints

- macOS 14.0+ (Sonoma) minimum deployment target
- Must work with the existing plugin system (unknown `DatabaseType` values from future plugins)
- Must not break iCloud sync (export/import is orthogonal to CloudKit sync)
- File format must be forward-compatible (versioned, unknown fields ignored)
- Export file must be < 1MB for typical usage (100 connections)
