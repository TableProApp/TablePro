# Storage

TablePro uses XDG files for local state, SQLite for query history, a JSONL audit journal, and Secret Service for credentials. The code is split between `tablepro-storage` and focused application services.

## Locations

| Data | Format | Default path |
|---|---|---|
| Saved connections | Versioned JSON | `$XDG_CONFIG_HOME/tablepro/connections.json` |
| Preferences | GSettings with JSON rollback mirror | `com.tablepro.linux` and `$XDG_CONFIG_HOME/tablepro/preferences.json` |
| Window state | GSettings geometry with JSON rollback mirror | `com.tablepro.linux` and `$XDG_CONFIG_HOME/tablepro/window.json` |
| Workspace tabs | JSON | `$XDG_CONFIG_HOME/tablepro/workspace_state.json` |
| Column widths | JSON | `$XDG_CONFIG_HOME/tablepro/column_widths.json` |
| Table filters | JSON | `$XDG_CONFIG_HOME/tablepro/filter_settings.json` |
| Query history | SQLite with FTS5 | `$XDG_CONFIG_HOME/tablepro/history.db` |
| Policy | TOML | `$XDG_CONFIG_HOME/tablepro/policy.toml` |
| Audit journal | Hash-chained JSONL | `$XDG_DATA_HOME/tablepro/audit.jsonl` |
| Database passwords, SSH passwords, SSH key passphrases, MCP secrets | Secret Service through `oo7` | Desktop keyring |

If `XDG_CONFIG_HOME` is unset, config storage falls back to `~/.config/tablepro/`. If `XDG_DATA_HOME` is unset, the audit journal falls back to `~/.local/share/tablepro/`. A development build uses `tablepro-devel` in place of `tablepro` for every path above, the policy file included.

The current history database is under XDG config because that is what `query_history::db_path()` implements. Do not document or migrate it to XDG data without a code change and a tested migration.

## Saved connections

`tablepro-storage` exposes `load_connections`, `save_connections`, `delete_connection`, and `touch_last_opened`. The file has a top-level version and a connection array. Loading rejects unsupported versions.

Connection records contain host, port, database, username, TLS mode, read-only state, authentication mode, environment, optional SSH configuration, and optional last-opened time. Passwords and SSH secrets are not part of the JSON record.

`save_connections` writes a temporary file beside `connections.json` and renames it over the destination. The application JSON services use the same write-then-rename shape with per-process temporary names. These writes do not claim crash durability beyond what the current code provides.

## Preferences and UI state

Application services own preferences, window state, workspace state, column widths, and table filters. They read from the XDG config directory and use defaults when a file is absent or cannot be decoded. Preferences and window geometry use GSettings when its schema is installed; the development build has a separate `com.tablepro.linux.Devel` schema. The last connection id remains in `window.json`. On first use, legacy `preferences.json` and `window.json` are copied to private `*.before-gsettings.json` files before migration. Every later save also writes the JSON files, so an older package can read current values after rollback. Preferences validate migration writes by reading them back, refuse future migration versions, and block edits when a legacy source is malformed. A failed JSON mirror write rolls back the preferences update. Cargo compiles the same schema used by packages for source-tree runs. If the schema is unavailable, the JSON files remain the source of both settings. To restore the original pre-migration values, copy `preferences.before-gsettings.json` over `preferences.json` after closing BookiE, then restart the newer package; it imports the restored JSON values. For window state, use the matching `window.before-gsettings.json` backup and reset `window-migrated`.

Window state stores size, maximize flag, and the last connection id. Closing a window keeps that id so the next launch can reopen the same connection. An explicit disconnect or deleting that saved connection clears it. Geometry writes do not drop the last connection id.

Workspace state is keyed by connection UUID and limited before it is written. Unknown tab variants deserialize as `Unknown` and are dropped during restore. This lets an older build ignore a newer tab kind without rejecting the whole workspace file.

## Query history

History schema upgrades use SQLite transactions. Before changing an existing database, the store makes a private SQLite snapshot at `history.before-migrations.db` while holding its storage lock. To roll back the history format, close BookiE, move the upgraded `history.db` and its `-wal`/`-shm` companions aside, then copy `history.before-migrations.db` to `history.db` with mode `0600`. History entries added after the snapshot will not be in the restored file.


`tablepro_storage::query_history` owns a single SQLite pool. `init()` creates `history.db`, enables WAL mode, creates the `history` table, and creates an FTS5 virtual table with triggers that follow inserts, deletes, and query text updates.

History records include query text, driver and connection identity, execution time, duration, affected rows, success, cancellation, pin state, and an optional error. Search supports text, connection, outcome, time, and limit filters. Unpinned entries can be pruned by age.

A query larger than 1 MiB is rejected by the history recorder.

History export from the GUI writes through a temporary sibling file and a rename, the same way current-page CSV and JSON export do.

## Policy

The GUI loads `$XDG_CONFIG_HOME/tablepro/policy.toml` at startup. A missing file uses the built-in defaults. A file that exists but cannot be read or parsed is refused: the GUI uses defaults, disables MCP, and a later reload that fails keeps the policy already in memory. An explicit empty `mask_patterns` list is treated as the default sensitive-field patterns. `tablepro-agentd` still requires a readable `--policy` path and does not start without one.

## Audit journal

`AuditJournal::open_default()` opens `$XDG_DATA_HOME/tablepro/audit.jsonl`. Initialization creates the parent directory, sets the journal mode to `0600`, verifies the hash chain, recovers safe trailing fragments, and reports unresolved operation IDs.

Each record contains a sequence number, previous hash, current hash, and audit event. Mutation intents and transaction commit records use the durable append path. File locks serialize initialization and appends across processes.

The GUI and `tablepro-agentd` may hold the journal at the same time. Each live
owner holds a shared process lock; startup recovery requires the exclusive lock,
so a second process does not record another process's in-flight mutation as
`Unknown`. It validates the chain without recovery. New write intents are still
refused while an earlier write remains pending. After all owners exit, the next
opener recovers any intents left pending by a crash.

Every append currently verifies the full journal, and `recent(limit)` reads the
full file before trimming its result. Append cost therefore grows with journal
size; the 1,000-append concurrency test takes about 25 seconds locally. There is
no retention or compaction policy. Keep the full-chain integrity check until a
checkpoint/rotation design can preserve crash recovery and tamper detection;
do not prune audit history as a performance shortcut.

The GTK application disables governed writes and MCP startup when the required audit journal cannot be opened or reports unresolved writes. `tablepro-agentd` also refuses startup when the journal is unavailable or reports unresolved writes.

## Secrets

The secrets module uses `oo7::Keyring`, which talks to the Linux Secret Service API. Items use the schema `com.tablepro.linux.Password` and attributes for `connection-id` and `kind`.

The implemented kinds are:

- Database password
- SSH password
- SSH private-key passphrase
- MCP token secret

Loaded values are returned as `secrecy::SecretString`. An absent item returns `Ok(None)`. Secret Service failures return a typed `StorageError`, distinguishing unavailable, locked and cancelled access; saved transport assembly propagates that failure instead of treating it as a missing password. It does not copy the value into a JSON file.

## Change rules

When changing storage behavior:

1. Keep secrets out of JSON and logs.
2. Preserve existing file locations unless the change includes a tested migration.
3. Keep saved connection versions explicit and reject versions the code cannot read.
4. Test missing files, malformed or unsupported data, round trips, and migration behavior.
5. Keep audit failures fail-closed for governed writes. A policy file that cannot be read must not become an empty or silently defaulted policy for MCP.
6. Update this document from the implementation, not from planned APIs.

## Query favorites

`$XDG_CONFIG_HOME/tablepro/favorites.json` holds saved queries as `{version, favorites[]}`, written through a temporary file and a rename. Each entry keeps an id, name, statement, optional driver and connection ids, a creation time, and a last-used time. Saving a name that already exists replaces that entry's statement and keeps its id. The file is capped at 500 entries, and a name or statement that is only whitespace is rejected.

## Connection bundles

A connection bundle is a single JSON document a user exports and another
machine imports. It is not a storage location: nothing reads or writes it
automatically.

```json
{"format": "tablepro.connection-bundle", "version": 2, "producer": "...", "exported_at": "...", "payload": {...}}
```

Version 2 is written by current exports. Imports continue to accept version 1
bundles, which carry only legacy connection-level SSH secrets when encrypted.

`payload.kind` is `plaintext` or `encrypted`, matched by hand rather than
through an internally tagged enum, because `#[serde(deny_unknown_fields)]`
does not reach through `#[serde(tag = ...)]`.

### What a bundle carries

Exported: `id`, `name`, `driver_id`, `host`, `port`, `socket_dir`,
`database`, `username`, `tls_mode`, `tls_root_cert`, `read_only`,
`auth_mode`, `environment`, `ssh`, plus the group, tags and colour from
the organisation sidecar.

Withheld: `use_tls` (the legacy boolean `tls_mode` replaced, so no bundle
can claim `use_tls: true, tls_mode: disabled`), `last_opened_at` (local
telemetry), unknown keys carried from a newer version, the contents of
`tls_root_cert` and any SSH private key (paths only), and policy
`connection_overrides`.

`BUNDLE_INCLUDED_FIELDS` and `BUNDLE_EXCLUDED_FIELDS` must together equal
`KNOWN_CONNECTION_FIELDS`. A unit test asserts this, so a new field on
`SavedConnection` fails the build until someone classifies it.

### Credentials

A plaintext bundle carries no credentials at all. Only the encryption
path populates `secrets`, and the parser rejects a plaintext payload that
arrives with a non-empty `secrets` list.

An encrypted version 2 bundle carries the database password, legacy
connection-level SSH credentials where needed, and each versioned SSH hop's
password or key passphrase bound to its hop ID and credential revision. A
version 1 bundle carries only the database password and legacy SSH password
or passphrase. Neither version carries an MCP token: a token is an
authorization grant tied to allowlists on the exporting machine, a
different trust class from a database credential.

### Encryption

Argon2id derives the key (`memory_kib = 131072`, `iterations = 3`,
`parallelism = 1`, 16-byte salt, 32-byte output), because a bundle is
offline-attackable and the KDF has to be memory-hard. On import the header
parameters are range-checked before any derivation runs: memory
19456..=1048576 KiB, iterations 1..=16, parallelism 1..=4, salt exactly 16
bytes. An unchecked header is a memory bomb.

AES-256-GCM seals the body with a 12-byte random nonce. The header is
bound to the ciphertext through the AAD, so an attacker cannot hand back a
bundle whose `memory_kib` has been downgraded. The AAD has a fixed byte
layout built by a dedicated function rather than re-serialized JSON,
because this workspace's `serde_json` runs with `preserve_order` and a
rewritten document is not byte-stable.

A wrong passphrase and a tampered file produce one indistinguishable
error.

### Importing

`plan_import` is pure and decides one disposition per entry:

| Situation | Disposition |
|---|---|
| The id is not in use locally | `New` — keep the id, so a restored backup lines up with a restored keyring, organisation file, favourites and history |
| The id is in use at the same endpoint | `UpdateInPlace` |
| The id is in use at a different endpoint | `Remapped` — a fresh `Uuid`; the audit journal, history rows and policy overrides already bind that id to another server |
| Two bundle entries share an id | The whole bundle is rejected |
| A local connection the bundle omits | Untouched; import is additive and has no delete path |

An endpoint is `(driver_id, lowercased host, port, socket_dir, database,
username, SSH hop chain)`. Name, TLS mode, read-only, environment and auth
mode are settings, not identity.

On an in-place update safety never downgrades: `read_only` is the OR of
both, `environment` the higher of Local < Dev < Staging < Prod, `tls_mode`
the stricter of Disabled < Prefer < Require < VerifyCa < VerifyFull, and
`last_opened_at` keeps the local value. A bundle can tighten a local
connection and never loosen it.

`apply_import` takes the connection-file lock once and rewrites the file
in a single pass, so a plan lands whole rather than as N upserts racing
another process.

Exporting a bundle is not recorded in the audit journal. The journal is
hash-chained and its event schema is SQL-shaped, so carrying a non-SQL
event through it needs its own change.
