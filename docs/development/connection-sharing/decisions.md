# Architecture Decision Records (ADRs)

---

## ADR-001: JSON as Export Format

**Status:** Accepted
**Date:** 2026-03-26

### Context

Need to choose a file format for exported connections. Options considered:
- JSON
- XML (like DataGrip's `dataSources.xml`, Navicat's NCX)
- Plist (like Sequel Ace's SPF)
- YAML
- Proprietary binary (like TablePlus's `.tableplusconnection`)

### Decision

**JSON** with `.tablepro` file extension.

### Rationale

1. **Git-friendly** — human-readable diffs, mergeable by text, reviewable in PRs
2. **Native Swift support** — `Codable` with `JSONEncoder`/`JSONDecoder`, no third-party dependency
3. **Inspectable** — users can open in any text editor, verify no credentials leaked
4. **Ecosystem standard** — DBeaver (the most Git-friendly competitor) uses JSON; pgAdmin and MongoDB Compass also use JSON
5. **Forward-compatible** — unknown keys ignored by older parsers, versioned with `formatVersion`

### Rejected

- **XML**: verbose, harder to diff, not a natural fit for Swift (`Codable` maps directly to JSON)
- **Plist**: Apple-specific, not Git-friendly in binary form, XML plist is verbose
- **YAML**: requires third-party parser (no stdlib support in Swift), whitespace-sensitive
- **Proprietary binary**: not inspectable, not diffable, not automatable

---

## ADR-002: Name-Based References Instead of UUIDs

**Status:** Accepted
**Date:** 2026-03-26

### Context

Connections reference tags and groups by UUID. Exported files need to handle these references across machines where UUIDs won't match.

### Decision

Export uses **name-based references** (`tagName`, `groupName`) instead of UUIDs. Connection UUIDs are **not exported** — new UUIDs are generated on import.

### Rationale

1. **Portability** — UUIDs are machine-specific. Tag UUID `abc-123` on machine A means nothing on machine B
2. **Human readability** — `"tagName": "production"` is self-documenting; `"tagId": "00000000-..."` is not
3. **Merge-friendly** — name collisions are meaningful (same-named tag = same tag); UUID collisions are random
4. **Preset tags** — The 4 preset tags (local, dev, prod, testing) have fixed UUIDs, but name-matching works for both presets and custom tags

### Consequences

- Tags/groups with duplicate names on target machine: matched to first found (case-insensitive)
- Custom tags not on target: auto-created with exported color
- Groups not on target: auto-created with exported color
- SSH profiles: inlined rather than referenced (avoids needing profile name matching)

---

## ADR-003: Credentials Never in Export by Default

**Status:** Accepted
**Date:** 2026-03-26

### Context

Every competitor except Navicat and HeidiSQL excludes credentials from exports by default. Security best practice is clear, but some users want one-file sharing including passwords.

### Decision

**Default export is always credential-free.** Optional encrypted export with AES-256-GCM when user explicitly checks "Include Credentials" and provides a passphrase.

### Rationale

1. **Security by default** — accidental credential exposure is the #1 risk in connection sharing
2. **Git-safe** — default export can be committed to version control without risk
3. **Industry standard** — DBeaver (never), DataGrip (never), MongoDB Compass (optional+encrypted), MySQL Workbench (always encrypted)
4. **User choice** — encrypted option covers the "share with trusted colleague" use case

### Encryption Specification

- Algorithm: AES-256-GCM (authenticated encryption)
- Key derivation: PBKDF2-SHA256 with 600,000 iterations (OWASP 2023 recommendation)
- Salt: 32 bytes random (per file)
- Nonce: 12 bytes random (per file)
- Header: `TPRO` magic bytes (4 bytes) + version byte for format detection
- Uses Apple CryptoKit (no third-party dependency)

### Rejected

- **Always encrypted** (MySQL Workbench style): too heavyweight for simple sharing, breaks Git-friendliness
- **Weak encryption** (Navicat AES-128 style): known broken by security researchers
- **No encryption option at all** (DBeaver/DataGrip style): prevents legitimate use case of full sharing with trusted colleagues

---

## ADR-004: Linked Folders via FSEvents (Not CloudKit Shared DB)

**Status:** Accepted
**Date:** 2026-03-26

### Context

Team sync could be implemented via:
1. CloudKit shared database (real-time sync, Apple ID invites)
2. File-based sync with directory watching (Git/Dropbox/network drive)
3. Custom server (like Navicat On-Prem)

### Decision

**File-based sync via FSEvents-monitored directories** (Linked Folders). Inspired by DbVisualizer's mounted folders.

### Rationale

1. **Zero infrastructure** — uses existing tools (Git, Dropbox, iCloud Drive, network shares)
2. **Developer-native** — teams already use Git repos for shared config; this fits their workflow
3. **Simple conflict model** — file is source of truth, local overrides are personal (Keychain)
4. **Incremental** — can ship in stages; full CloudKit shared DB is a separate, much larger project
5. **Platform-neutral source** — `.tablepro` JSON files could theoretically be generated by scripts, Terraform, Ansible — not tied to Apple ecosystem

### Consequences

- No real-time push notifications (polling/FSEvents granularity)
- No user identity or permissions (file system permissions are the access control)
- No audit trail (Git history serves this purpose)
- Credentials must be per-user (each user has their own Keychain entries)

### Future

CloudKit shared database (ADR for later) would complement this for users who want real-time sync without Git. Not a replacement — both serve different workflows.

---

## ADR-005: Path Portability via Tilde Expansion

**Status:** Accepted
**Date:** 2026-03-26

### Context

SSH key paths and SSL cert paths are absolute on the exporter's machine (`/Users/dat/.ssh/id_rsa`). These won't exist at the same path on another machine.

### Decision

**Convert home-relative paths to `~/` form on export.** Expand `~` to current user's home on import. Validate file existence, warn if missing but still import.

### Rationale

1. **SSH keys conventionally live under `~/.ssh/`** — `~/.ssh/id_rsa` works across all macOS users
2. **SSL certs often under `~/certs/` or `~/Library/`** — tilde covers most cases
3. **System paths preserved** — `/etc/ssl/cert.pem` stays absolute (not under home dir)
4. **Non-blocking** — missing files generate warnings, not errors. User can fix path after import.

### Edge Cases

- Symlinks: preserved as-is (not resolved)
- Paths outside home dir: kept absolute
- Environment variable paths (`$SSH_KEY_PATH`): preserved as-is (Tier 2 feature)

---

## ADR-006: Duplicate Detection Strategy

**Status:** Accepted
**Date:** 2026-03-26

### Context

When importing connections, some may already exist on the target machine. Need a strategy to detect and handle duplicates.

### Decision

**Match on `name + host + port + type` (case-insensitive name).** Offer three resolution options per duplicate: Skip, Replace, Import as Copy.

### Rationale

1. **Name alone is ambiguous** — multiple connections named "Production" for different databases
2. **Host+port+type alone is ambiguous** — same server, different connection names with different settings
3. **All four together** is high confidence — same name pointing to same server of same type is almost certainly the same connection
4. **User choice** — automatic dedup is risky; showing duplicates and letting user decide is safer

### Rejected

- **UUID-based matching**: UUIDs are not exported (ADR-002), so can't match
- **Host+port only**: too aggressive, would match different databases on same server
- **Automatic replace**: too risky without user confirmation
- **Automatic skip**: hides duplicates from user, may miss intentional updates

---

## ADR-007: Inline SSH Config (Drop sshProfileId on Export)

**Status:** Accepted
**Date:** 2026-03-26

### Context

Connections can reference reusable SSH profiles via `sshProfileId`. These profiles have their own UUIDs that won't match across machines.

### Decision

**Always inline the SSH configuration on export.** Drop `sshProfileId`. Export SSH profiles separately in the `sshProfiles` array for the user to set up, but connections carry their full SSH config.

### Rationale

1. **Self-contained connections** — each connection works independently, no dangling references
2. **Simpler import** — no need to match or create SSH profiles before importing connections
3. **SSH profiles are still exported** — users who want to set up shared profiles can import them separately and re-link manually
4. **Matches user mental model** — when you share a connection, you expect it to "just work" (minus credentials)

### Consequence

- If 10 connections share the same SSH profile, the export has 10 copies of the SSH config. This is a small size cost (< 1KB per SSH config) for much simpler import logic.
