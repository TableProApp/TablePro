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

- Schema name: `app.tablepro.TablePro.Password`. Attributes: `connection-id`. Label: human-readable connection name (kept in sync on rename).
- If libsecret is not available (rare; truly minimal Linux installs), `load_password` returns `Ok(None)` and the UI prompts at connect time. The app does not crash and does not write passwords to plain files as a fallback.
- Never log a password, ever. Wrap them in `secrecy::SecretString` from the `secrecy` crate before they leave the storage layer.

## Where files go

`tablepro_storage::StoragePaths` resolves every directory once at startup
through GLib, so the app agrees with the rest of the desktop about the XDG
base directories and their fallbacks.

| Accessor | Path |
|---|---|
| `connections_file()` | `$XDG_CONFIG_HOME/<dir>/connections.json` |
| `column_widths_file()` | `$XDG_CONFIG_HOME/<dir>/column_widths.json` |
| `filter_settings_file()` | `$XDG_CONFIG_HOME/<dir>/filter_settings.json` |
| `history_database()` | `$XDG_STATE_HOME/<dir>/history.db` |
| `workspace_state_file()` | `$XDG_STATE_HOME/<dir>/workspace_state.json` |
| `drafts_dir()` | `$XDG_DATA_HOME/<dir>/drafts` |
| `instance_lock()` | `$XDG_RUNTIME_DIR/app/<app-id>/tablepro.lock` |

`<dir>` is `tablepro` for an installed build and `tablepro-devel` for a
development one, so `cargo run` never writes over an installed build's
files. `StoragePaths::under(root, ..)` builds the same layout under a
temporary root, which is how the tests stay off the developer's own data.

## Writing files

Everything private goes through `tablepro_storage::fs`:

- `ensure_private_dir` creates the directory tree and sets the leaf to
  exactly 0700. `DirBuilder::mode` only applies to directories the call
  creates, so an existing 0755 directory still needs the explicit chmod.
- `write_private_blocking` writes through `g_file_set_contents_full` with
  `CONSISTENT | DURABLE`: a reader sees the old file or the new one, never
  a mix, and the new one survives a power cut. It tightens an existing
  file to 0600 first, because that call keeps an existing file's mode and
  only applies the mode argument when it creates the file.
- `create_private_file_if_missing` pre-creates an empty 0600 file. SQLite
  creates its database, WAL and SHM with the umask mode, so pre-creating
  the database is what keeps all three off world-readable.

These calls block on `fsync`, so async callers run them through
`spawn_blocking` rather than on the GTK thread.

## App preferences with `gio::Settings`

`data/app.tablepro.TablePro.gschema.xml` holds every app-wide preference and the window geometry. Meson installs it to `$datadir/glib-2.0/schemas` and compiles it; see [ADR 0007](decisions/0007-gsettings-preferences.md).

Schema id and path: `app.tablepro.TablePro`.

| Key | Type | Default | Range |
|---|---|---|---|
| `window-width` | `i` | `1200` | 360 to 32767 |
| `window-height` | `i` | `760` | 294 to 32767 |
| `is-maximized` | `b` | `false` | |
| `default-page-size` | `u` | `1000` | 100 to 100000 |
| `confirm-destructive` | `b` | `true` | |
| `history-retention-days` | `u` | `30` | 0 to 365 |
| `query-timeout-secs` | `u` | `60` | 0 to 3600 |
| `use-system-font` | `b` | `true` | |
| `custom-font` | `s` | `Monospace 12` | |
| `style-scheme` | `s` | `Adwaita` | |
| `csv-null-to-empty` | `b` | `true` | |
| `csv-line-break-to-space` | `b` | `false` | |
| `csv-header-row` | `b` | `true` | |
| `csv-sanitize-formulas` | `b` | `true` | |
| `csv-delimiter` | enum | `comma` | comma, semicolon, tab, pipe |
| `csv-quote` | enum | `if-needed` | always, if-needed, never |
| `csv-line-break` | enum | `lf` | lf, crlf, cr |
| `csv-decimal` | enum | `period` | period, comma |

`tablepro_storage::AppSettings` wraps it in typed accessors:

```rust
pub fn open(schema_id: &str) -> Result<Self, SettingsError>;
pub fn gio(&self) -> &gio::Settings;
pub fn default_page_size(&self) -> u32;
pub fn query_timeout(&self) -> Option<Duration>;
pub fn editor_font(&self) -> EditorFont;
pub fn csv_options(&self) -> CsvOptions;
pub fn window_geometry(&self) -> WindowGeometry;
```

Three points worth knowing:

- `gio::Settings::new` aborts the process when the schema is missing, so `open` looks the id up through `SettingsSchemaSource::default()` first and returns `SettingsError::SchemaNotFound`.
- A `<range>` makes GSettings refuse an out-of-bounds write. `AppSettings` surfaces that refusal as `SettingsError::Write` rather than silently storing it.
- `query_timeout()` returns `Option<Duration>`; zero seconds means no timeout, and the type says so.

Preference rows bind straight to the schema with `settings.gio().bind(key, &row, prop)`, so a change reaches every open view through `changed::<key>` without a save step.

High-churn keyed data stays in files: column widths, per-table filters and workspace tabs are unbounded maps, which is not what GSettings is for.

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
