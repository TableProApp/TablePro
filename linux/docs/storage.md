# Storage

Three persistence backends, used for different data shapes. Each is owned by the `storage` crate; nothing else in the workspace touches the filesystem, libsecret, or `gio::Settings` directly.

| Data | Backend | Crate API |
|---|---|---|
| Connection metadata (host, port, db, etc.) | JSON file in XDG | `storage::connections` |
| Passwords | libsecret via `oo7` | `storage::secrets` |
| App preferences (theme, last window size, etc.) | `gio::Settings` (GSchema) | `storage::settings` |
| Query history | SQLite (FTS5) — **deferred to Phase 2** | `storage::history` (does not exist yet) |
| Tab state | JSON file — **deferred to Phase 2** | `storage::tabs` (does not exist yet) |

## File locations

All paths follow the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html). Defaults assume the user has not overridden `XDG_CONFIG_HOME` or `XDG_DATA_HOME`.

| Path | Purpose |
|---|---|
| `$XDG_CONFIG_HOME/tablepro/connections.json` | Connection list, ordered, with metadata |
| `$XDG_CONFIG_HOME/tablepro/groups.json` | Connection groups |
| `$XDG_DATA_HOME/tablepro/history.db` | SQLite FTS5 query history (Phase 2) |
| `$XDG_DATA_HOME/tablepro/tabs.json` | Open-tab snapshots (Phase 2) |
| `$XDG_CACHE_HOME/tablepro/` | Anything regenerable. Schema caches, parsed manifests. |

In Flatpak, these resolve under the sandboxed home, which is the correct behaviour. Do not reach outside the sandbox.

## Connection metadata

`storage::connections` exposes:

```rust
pub async fn load_connections() -> Result<Vec<SavedConnection>, StorageError>;
pub async fn save_connections(connections: &[SavedConnection]) -> Result<(), StorageError>;
pub async fn save_connection(connection: &SavedConnection) -> Result<(), StorageError>;
pub async fn delete_connection(id: ConnectionId) -> Result<(), StorageError>;
```

Implementation rules:

- Writes are atomic: write to `connections.json.tmp`, fsync, rename. Same pattern as the macOS app's `ConnectionStorage`.
- The JSON schema includes a `version` field. Migrations live in `storage::connections::migrate`. Never silently change the on-disk shape.
- A `SavedConnection` does **not** carry the password. Passwords are stored separately in libsecret, keyed by the connection's UUID.

### SSH settings

`SavedConnection.ssh` holds an optional `SavedSshConfig`:

- `host`, plus optional `port` and `username`. Leaving them out lets `~/.ssh/config` decide once the OpenSSH transport is in use.
- `jump_hosts`: `[user@]host[:port]` entries, empty for a direct connection.
- `auth`, tagged by `kind`: `agent`, `private_key` (optional `path` and `has_passphrase`), `password` or `keyboard_interactive`.

SSH passwords and key passphrases live in libsecret next to database passwords. Until the OpenSSH transport lands, the russh tunnel serves `password`, and `private_key` with a path, when the port and user are set and there are no jump hosts. Any other stored combination fails before any network I/O with an error that names the setting.

## Passwords with libsecret

`storage::secrets` exposes:

```rust
pub async fn store_password(id: ConnectionId, password: &str) -> Result<(), StorageError>;
pub async fn load_password(id: ConnectionId) -> Result<Option<String>, StorageError>;
pub async fn delete_password(id: ConnectionId) -> Result<(), StorageError>;
```

Backed by the [`oo7`](https://crates.io/crates/oo7) crate, which speaks the Secret Service D-Bus API. Both GNOME Keyring and KWallet implement it.

Notes:

- Schema name: `com.tablepro.linux.Password`. Attributes: `connection-id`. Label: human-readable connection name (kept in sync on rename).
- If libsecret is not available (rare; truly minimal Linux installs), `load_password` returns `Ok(None)` and the UI prompts at connect time. The app does not crash and does not write passwords to plain files as a fallback.
- Never log a password, ever. Wrap them in `secrecy::SecretString` from the `secrecy` crate before they leave the storage layer.

## App preferences with `gio::Settings`

A GSchema XML file lives at `linux/data/com.tablepro.linux.gschema.xml`. It is compiled at build time and installed by Flatpak / `meson` / `cargo` build scripts.

Schema namespace: `com.tablepro.linux`. Keys we expect to start with:

| Key | Type | Default |
|---|---|---|
| `theme` | `s` (`auto` / `light` / `dark`) | `auto` |
| `editor-font` | `s` | `JetBrains Mono 11` |
| `editor-tab-width` | `u` | `4` |
| `result-grid-row-height` | `u` | `28` |
| `last-window-width` | `u` | `1200` |
| `last-window-height` | `u` | `760` |
| `last-window-maximised` | `b` | `false` |

`storage::settings` wraps `gio::Settings` so the rest of the app reads typed values:

```rust
pub fn theme() -> Theme;
pub fn set_theme(theme: Theme);
pub fn editor_font() -> String;
pub fn last_window_size() -> (u32, u32);
```

Do not call `gio::Settings` directly from UI code. Always go through `storage::settings`. This isolates the schema from accidental misuse and makes future migration possible.

## Errors

`StorageError` is a `thiserror` enum exported from `storage`. Variants:

- `Io(std::io::Error)`
- `Serde(serde_json::Error)`
- `Secret(oo7::Error)`
- `Schema(String)` — schema mismatch, migration failed
- `NotFound`

UI code matches on these variants to display useful messages, not the raw `Display` output. See [error-handling.md](error-handling.md).

## Migration policy

When the on-disk shape changes:

1. Bump the `version` field in the schema.
2. Add a migration step in `storage::*::migrate`.
3. Test loading the previous version's fixture in `tests/`.
4. Update this file and the changelog.

Never break old user data without a migration step. Users have years-worth of saved connections.
