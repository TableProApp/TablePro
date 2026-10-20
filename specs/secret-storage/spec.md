# Secret storage

> [NEEDS REVIEW] Draft written on 2026-10-11 from `tablepro-storage` secrets, paths, transport keyring mapping and [ADR 0004](../../docs/decisions/0004-libsecret-secret-storage.md). A maintainer review is pending.

**Spec tier:** buildable **Serves:** `Local DBA`, `MCP operator` **Implementation:** shipped under [ADR 0004](../../docs/decisions/0004-libsecret-secret-storage.md) **Specification:** draft pending review **Success metric:** Keyring failure is never treated as a missing password; connection JSON never holds a secret.

## Purpose

Distinguish "no item stored" from "keyring unavailable, locked or cancelled", and keep credentials out of application JSON. XDG layout, history and bundle crypto stay in the [storage guide](../../docs/storage.md).

## Scope

- Secret Service access through `oo7` (`store_*` / `load_*` / `delete_*` in `crates/storage/src/secrets.rs`).
- Item schema and attributes (`secret_schema` in `crates/storage/src/paths.rs`).
- Typed `KeyringFailure` (`crates/storage/src/error.rs`).
- Transport refusing assembly on keyring failure (`secret_error` in `crates/transport/src/lib.rs`).
- The invariant that `SavedConnection` JSON omits password fields.

## Out of scope

- What SQL may run after connect ([governed-sql](../governed-sql/spec.md)).
- SSH host-key trust ([ssh-transport](../ssh-transport/spec.md)).
- XDG paths, query history, audit journal, preferences and bundle crypto ([storage guide](../../docs/storage.md)).
- Flatpak portal and sandbox Secret Service wiring (packaging / PKG-8).

## Core concepts

- **Absent vs failed.** `Ok(None)` means no matching item. `Err(StorageError::Keyring(_))` means the service could not be used.
- **Profile identity.** Development builds use `com.tablepro.linux.Devel.Password`; release builds use `com.tablepro.linux.Password`.

## Data contracts

`KeyringFailure` (`crates/storage/src/error.rs`):

```text
Unavailable
Locked
UnlockCancelled
Other(String)
```

Connection-scoped kind attributes (`crates/storage/src/secrets.rs`):

| Kind attribute | API |
|---|---|
| `db_password` | `store_password` / `load_password` / `delete_password` |
| `ssh_password` | `store_ssh_password` / `load_ssh_password` / `delete_ssh_password` |
| `ssh_passphrase` | `store_ssh_passphrase` / `load_ssh_passphrase` / `delete_ssh_passphrase` |
| `mcp_token` | `store_mcp_token` / `load_mcp_token` / `delete_mcp_token` |

Per-hop SSH secrets add `hop-id` and `credential-revision`:

| Kind attribute | API |
|---|---|
| `ssh_hop_password` | `store_ssh_hop_password` / `load_ssh_hop_password` / `delete_ssh_hop_password` |
| `ssh_hop_passphrase` | `store_ssh_hop_passphrase` / `load_ssh_hop_passphrase` / `delete_ssh_hop_passphrase` |

Loaded values are `secrecy::SecretString`.

## Interface contracts

### Store / load / delete

`open`, `load_secret_with_attrs` and `keyring_failure` in `crates/storage/src/secrets.rs`.

1. Open the default keyring (`Keyring::new`). A non-classified open failure becomes `KeyringFailure::Unavailable`.
2. Address items with `xdg:schema`, `connection-id` and `kind` (plus hop fields when scoped).
3. Return `Ok(None)` when search finds no item.
4. Map D-Bus `Dismissed` → `UnlockCancelled`, `IsLocked` → `Locked`, missing-service markers → `Unavailable`.

### Transport assembly

`secret_error` maps `StorageError::Keyring(failure)` to `TransportError::Keyring(failure)` and does not continue as if the password were absent.

An absent item (`Ok(None)`) is not a keyring failure. `connect_options_for` then uses an empty `SecretString` for the database password.

| Endpoint | Status | errorCode | Message / condition |
|----------|--------|-----------|---------------------|
| `load_*` | n/a | none | No matching item → `Ok(None)`. |
| `load_*` / `store_*` | n/a | `Keyring(Unavailable)` | No Secret Service, or unclassified open failure. |
| `load_*` / `store_*` | n/a | `Keyring(Locked)` | Collection locked. |
| `load_*` / `store_*` | n/a | `Keyring(UnlockCancelled)` | Unlock prompt dismissed. |
| saved connect | n/a | `TransportError::Keyring` | Keyring failure while assembling a saved connection. |

## Algorithms & rules

1. Choose schema from `secret_schema()` so devel and release keyrings do not collide.
2. Address items by attributes, never by embedding the secret in `connections.json`.
3. On load: missing item → `None`; service error → typed `KeyringFailure`.
4. On transport: propagate keyring failure. Callers may offer an explicit prompt as recovery, not a file fallback.

## Requirements

- The desktop application MUST store database passwords, SSH passwords, SSH key passphrases and per-hop SSH secrets through Secret Service, not in connection JSON. GUI-issued MCP token plaintext is returned once and storage through Secret Service is attempted; issuance succeeds if this best-effort save fails. `TokenStore` persists only the token hash.
- `bookie-agentd` MUST persist only the MCP token hash in its token registry and MUST emit newly issued plaintext once to stdout or an explicitly selected owner-only token file.
- An absent item MUST return `Ok(None)`.
- Unavailable, locked or cancelled keyring access MUST return `StorageError::Keyring` with the matching `KeyringFailure`.
- Saved connection assembly MUST propagate keyring failure and MUST NOT treat it as a missing password.
- Development and release builds MUST use distinct secret schemas when `TABLEPRO_PROFILE=development` is compiled in.

## Invariants

- Connection JSON MUST NOT contain password or passphrase fields.
- A keyring failure MUST NOT be collapsed into `Ok(None)`.
- Secret values MUST remain in `secrecy` wrappers until the driver or SSH boundary.

## Config & flags

| Flag | Effect |
|------|--------|
| `TABLEPRO_PROFILE=development` (compile-time) | `com.tablepro.linux.Devel.Password` and `tablepro-devel` XDG dir name. |
| Desktop Secret Service | Required for persistent credentials. |

## Edge cases

- Opening the keyring with an unclassified error is reported as `Unavailable` (`open` in `secrets.rs`).
- Per-hop secrets bind `connection-id`, `hop-id`, `credential-revision` and kind so a revision bump uses a different attribute set.
- Encrypted connection bundles may carry secrets; plaintext bundles must not. MCP tokens are not exported in bundles ([storage guide](../../docs/storage.md)).

## Trust boundaries

- The desktop keyring is trusted local state. BookiE does not implement a second encrypted credential file.
- Connection JSON, preferences and audit records must never be a credential store.
- Bundle import that remaps a connection id must not assume the old keyring items apply to the new id.

## Cross-capability interactions

### ssh-transport

Transport loads hop and legacy SSH secrets here, then opens the tunnel. Host-key trust is separate.

### governed-sql

GUI-issued MCP token plaintext is returned once and best-effort stored here; issuance still succeeds if keyring storage fails. `bookie-agentd` instead emits plaintext once to stdout or an explicitly selected owner-only file. In both paths `tablepro-mcp` authenticates against the stored hash. Policy and audit never log the plaintext.

## Acceptance criteria

Each line names the tip proof. When the proof is code only, that is marked.

- **No JSON password.** GIVEN a saved SQLite or DuckDB connection WHEN the record is serialized THEN it has no `password` field. Proof: `local_sqlite_and_duckdb_records_do_not_store_password_fields`.
- **Absent vs failed.** GIVEN no matching keyring item WHEN `load_secret_with_attrs` finds none THEN the result is `Ok(None)`. Proof: code in `load_secret_with_attrs`. D-Bus mapping: `keyring_failures_are_told_apart` and `a_missing_secret_service_is_recognised_from_the_dbus_error_text`.
- **Unavailable / locked / cancelled.** GIVEN those D-Bus errors WHEN `keyring_failure` runs THEN the variants are `Unavailable`, `Locked` and `UnlockCancelled`. Proof: same unit tests. Live Secret Service absence is the isolated keyring tier, not this unit map.
- **Transport fail-closed.** GIVEN `StorageError::Keyring(_)` WHEN `secret_error` runs THEN the result is `TransportError::Keyring`. Proof: `secret_error` in `crates/transport/src/lib.rs`. No dedicated transport unit test; the GUI maps `TransportError::Keyring` in `connection_service.rs`.
- **Hop revision.** GIVEN hop attributes for revision N WHEN compared with revision N+1 THEN the attribute maps differ. Proof: `hop_secret_attributes_do_not_collide_across_hops_kinds_or_revisions`. A live load of the wrong revision is not separately tested.
- **Devel schema.** GIVEN `TABLEPRO_PROFILE=development` WHEN `secret_schema()` is read THEN it is `com.tablepro.linux.Devel.Password`. Proof: `profile_paths_and_secrets_share_an_identity`.

## Open questions

None known. Architect review of this draft is still the open checklist fork.
