# Storage

The app's data goes to the store its shape calls for. The `storage` crate owns the stores and the calls that write private files; the app crate's workspace, column-width and filter files go through those same calls in `tablepro_storage::fs`.

| Data | Backend | API |
|---|---|---|
| Saved connections | JSON file | `ConnectionStore` |
| Database passwords, SSH passwords and key passphrases | `oo7`: the host's Secret Service, or the Secret portal inside Flatpak | `SecretStore`, read at each connect by `KeyringCredentials` |
| Preferences and window geometry | `gio::Settings` | `AppSettings` |
| Query history and saved queries | SQLite, one database | `QueryHistory`, `SavedQueries` |
| Editor tab text | one file per tab | `DraftStore` |
| Open tabs, open sessions, column widths, filters | JSON files the app crate writes | `WorkspaceStore`, `OpenSessions`, `crates/app/src/persistence/` |

[Where files go](#where-files-go) has the paths.

## Connection metadata

`ConnectionStore` holds the saved-connection list, one store per storage root:

- `load_blocking`, `upsert_blocking`, `update_blocking`, `remove_blocking`, `touch_last_opened_blocking`, `import_blocking` and `export_blocking` run off the GTK thread. A change holds the store's lock across read, change and write, so two writers never lose an entry. `update_blocking` changes one entry as the list holds it at the write, so a last-opened stamp from another window in between is kept.
- A write goes through `write_private_blocking` first and the cached list changes only once it landed, so a failed write leaves both as they were.
- `subscribe` hands out a watch of `ConnectionListSnapshot`, so every picker sees every writer's change.
- A file that cannot be read, or that another version wrote, leaves the store `Unavailable`, and it refuses every write until the user picks Reset (`reset_unreadable_blocking`), which moves the file aside.
- A `SavedConnection` does **not** carry a password. Secrets live in the keyring, keyed by the connection's UUID, so a rename or a new host keeps them.
- `safe_mode` is the connection's Safe Mode level: `off`, `confirm_writes` or `read_only`. It has no default, since guessing Off would drop a guard. Version 1 of the file had a `read_only` switch instead, which reads as `read_only` when on and `off` when off.
- `external_access` is what MCP clients may do on the connection: `blocked`, `read_only` or `read_write` ([ADR 0022](decisions/0022-ai-assistant-and-mcp-server.md)). A file written before it existed reads as `read_only`, the level a new connection starts at.
- `ai_policy` is what the AI assistant may send from the connection: `ask`, `allow` or `never`. A file written before it existed reads as `ask`, the policy a new connection starts at.
- `group` is a `ConnectionGroupName`: trimmed, 1 to 64 characters, no control characters. Earlier builds stored any name, so a stored one is read with its control characters turned into spaces and cut to 64 characters, and a blank one reads as no group.
- The file's `tags` list holds every `ConnectionTag`: an `id`, a `name` (`ConnectionTagName`: trimmed, 1 to 32 characters, no control characters, cleaned on read as a group's is) and a `color` from the same palette as `color`. No two tags share a name in any case: `create_tag_blocking` and `update_tag_blocking` refuse one with `TagNameTaken`.
- A connection's `tags` are ids from that list. Every write drops an id the list lacks and a repeated one, so `delete_tag_blocking` takes the tag off every connection in the same write, and a connection saved with a tag deleted meanwhile loses it.
- `icon` is one of the `ConnectionIcon` names. The app draws each with a symbolic icon from the theme (`crates/app/src/ui/icons.rs`).
- On import, a tag is matched by id, then by name in any case, and added only when neither matches, so importing a file twice leaves one tag of each name. A tag matched by id takes the file's colour, and its name unless another tag has it. A connection updated by an import takes the file's tags and icon.
- An edit, a copy or a move to another group goes through the app's `SavedConnectionEditor`, which writes the keyring first. A refused secret stops before the list changes, and the secrets of a copy whose entry did not land are deleted again. Edits and copies run one at a time, so two windows editing one connection never leave the host of one with the password of the other.

### SSH settings

`SavedConnection.ssh` holds an optional `SavedSshConfig`:

- `host`, plus optional `port` and `username`. Leaving them out lets `~/.ssh/config` decide.
- `jump_hosts`: `[user@]host[:port]` entries, empty for a direct connection.
- `auth`, tagged by `kind`: `agent`, `private_key` (optional `path` and `has_passphrase`), `password` or `keyboard_interactive`.

SSH passwords and key passphrases sit in the keyring next to database passwords. The system OpenSSH client runs every combination ([ADR 0013](decisions/0013-openssh-client-transport.md)), and asks for a missing secret through the app's prompts.

## Passwords in the keyring

`SecretStore` is the app's `SecretVault`: `store`, `load`, `relabel`, `delete_kind` and `delete_connection`, keyed by connection id and `SecretKind`, with the secret as a `SecretString`.

Backed by the [`oo7`](https://crates.io/crates/oo7) crate ([ADR 0004](decisions/0004-libsecret-secret-storage.md)). Outside Flatpak it talks to the host's Secret Service over D-Bus, which GNOME Keyring and KWallet both implement. Inside Flatpak it keeps the items in an encrypted file in the sandbox, unlocked with a key from the Secret portal, and uses the Secret Service only when there is no portal.

Notes:

- Schema name: the application id plus `.Password`, so `app.tablepro.TablePro.Password` for an installed build and `app.tablepro.TablePro.Devel.Password` for a development one. Neither reads the other's secrets. Attributes: `xdg:schema`, `connection-id` and `kind` (`db_password`, `ssh_password`, `ssh_passphrase`).
- The MCP server's access token is one item of its own, with `xdg:schema` and `kind` `mcp_token` and no `connection-id`, so deleting a connection never matches it. It is made on the server's first start and replaced from Preferences.
- Each AI provider's API key is one item, with `xdg:schema`, `kind` `ai_api_key` and `provider` (`anthropic`, `openai` or `openai-compatible`) and no `connection-id`. Preferences > AI stores and removes it; the assistant reads it before each request.
- Labels name the kind and the target, for example `TablePro database password for app@db.example.com:5432/shop`, so the item is identifiable in Seahorse on a host install. Under Flatpak the items sit in the app's own file keyring.
- The store unlocks the keyring and the item before reading. A locked keyring otherwise looks exactly like a connection with no saved password.
- Failures are typed (`SecretError`): a dismissed prompt, a locked keyring, a missing service, a missing portal and a bad encoding each get their own message and their own next step.
- With no Secret Service at all the store reports `ServiceUnavailable` and the UI prompts at connect time. The app never writes passwords to a plain file as a fallback.
- Never log a password, ever. Wrap them in `secrecy::SecretString` from the `secrecy` crate before they leave the storage layer.

### When the keyring cannot supply a secret

`KeyringCredentials` reads each secret at every connect. What happens when
it cannot depends on whether someone is there to answer:

- A connect the user started, and the connect dialog's Test, run attended.
  A secret that is not stored, or that a locked or missing keyring cannot
  give, is asked for in a dialog over the window. A missing Secret Service
  or portal offers no Remember switch, since nothing could keep it.
- An SSH key with no stored passphrase is left to ssh, which asks through
  the same prompts at the hop that needs it.
- A secret typed with Remember on is stored only once the login it was
  typed for works. A store the keyring refuses is reported in a toast, and
  the connection stays open.
- A login the server refused offers Enter Password on the failed page. That
  retry passes `CredentialDemand::reenter`, which asks again without reading
  the keyring's copy, the one just refused.
- A secret typed for a session that the keyring does not hold, because
  Remember was off or the keyring refused it, is the one that session's
  reconnects use (`KeyringCredentials::keeping_session_secrets`). Otherwise a
  reconnect would log in with the stored copy the server refused.
- Background reconnects run unattended and never ask. A missing secret parks
  the session until the user presses Retry, which runs attended.
- A typed secret lives in a `SecretString`, and the prompt clears its rows
  as it hands the answer over.

## Deleting a connection

`ConnectionDeletion::run` removes a saved connection in an order that
leaves nothing unreachable behind when a step fails:

1. The keyring secrets. If the keyring refuses, nothing else runs and the
   entry stays: an entry with no secrets only asks for them again, while a
   secret with no entry is orphaned in the keyring.
2. The entry in `connections.json`.
3. Everything kept for it: column widths, filters, the saved tabs with any
   copy Reset moved aside, the editor drafts (`WorkspaceStore::purge`), the
   saved queries, and the query history when the user turned that on. A
   failure here is reported and does not bring the entry back.

A connection open or connecting in a window is not deleted; the dialog
offers that window instead. It asks once, in that one dialog. The delete
claims the connection's key while it runs, so a connect started meanwhile
from a picker that still lists it is refused. Every picker follows the list
the store publishes, so the row goes from each once the entry is removed,
and a menu still open on it finds no connection and does nothing.
The purge waits for the drafts a just-closed workspace is still writing
(`WorkspaceStore::writes_in_flight`). The window holds the process until the
delete ends, as it does for every other write to the connection list.

## Where files go

`tablepro_storage::StoragePaths` resolves every directory once at startup
through GLib, so the app agrees with the rest of the desktop about the
[XDG base directories](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
and their fallbacks. Under Flatpak they resolve inside the sandbox, and
nothing reaches outside it.

| Accessor | Path |
|---|---|
| `connections_file()` | `$XDG_CONFIG_HOME/<dir>/connections.json` |
| `column_widths_file()` | `$XDG_CONFIG_HOME/<dir>/column_widths.json` |
| `filter_settings_file()` | `$XDG_CONFIG_HOME/<dir>/filter_settings.json` |
| `history_database()` | `$XDG_STATE_HOME/<dir>/history.db` |
| `workspaces_dir()` | `$XDG_STATE_HOME/<dir>/workspaces`: one file per session, and `open-sessions.json` |
| `drafts_dir()` | `$XDG_DATA_HOME/<dir>/drafts` |
| `snippets_dir()` | `$XDG_DATA_HOME/<dir>/snippets`: the user's SQL editor snippets, made when Preferences opens it ([README](../README.md#snippets)) |
| `crashes_dir()` | `$XDG_STATE_HOME/<dir>/crashes`: crash reports ([error-handling.md](error-handling.md#crashes)) |

`<dir>` is `tablepro` for an installed build and `tablepro-devel` for a
development one, so `cargo run` never writes over an installed build's
files. `StoragePaths::under(root, ..)` builds the same layout under a
temporary root, which is how the tests stay off the developer's own data.

## Writing files

Everything private goes through `tablepro_storage::fs`:

- `ensure_private_dir` creates the directory tree and sets the leaf to
  exactly 0700. `DirBuilder::mode` only applies to directories the call
  creates, so an existing 0755 directory still needs the explicit chmod.
- `ensure_user_dir` creates a folder the user fills, such as the snippets
  folder, and what is missing above it as 0700, and leaves one that
  exists as it is: it may be a link to a folder other tools share.
- `write_private_blocking` writes through `g_file_set_contents_full` with
  `CONSISTENT | DURABLE`: a reader sees the old file or the new one, never
  a mix, and the new one survives a power cut. It tightens an existing
  file to 0600 first, because that call keeps an existing file's mode and
  only applies the mode argument when it creates the file.
- `append_private_blocking` appends to a file it creates 0600 when absent,
  for the crash report, which a second panic adds to.
- `create_private_file_if_missing` pre-creates an empty 0600 file. SQLite
  creates its database, WAL and SHM with the umask mode, so pre-creating
  the database is what keeps all three off world-readable.

These calls block on `fsync`, so async callers run them through
`Tasks::spawn_blocking_task`, never on the GTK thread.

## Query history schema

`QueryHistory` is the query history and, in the same database, the saved
queries (`QueryHistory::saved_queries`). It opens `history.db` with one
pooled connection in WAL mode, with sqlx's statement logging off, since
query text is the user's own SQL. It links the system SQLite: the trigram
tokenizer needs 3.34 or later, and `trigram_index_available_on_system_sqlite`
fails against an older one.

`crates/storage/migrations/` holds the schema as sqlx migrations, embedded
at compile time with `sqlx::migrate!` and run by `QueryHistory::open`:

1. `20260914000000_create_history.sql`: the `history` table.
2. `20260918000000_create_saved_queries.sql`: the saved queries.
3. `20261014000000_history_substring_search.sql`: adds `query_folded`,
   replaces the word index over `query` with the trigram index
   `history_search` over `query_folded`, and adds `history_page_idx` on
   `(pinned DESC, executed_at DESC, id DESC)` for paging.

**An applied migration is never edited.** Each change is a new timestamped
file with its own fixture test. Editing one in place changes its checksum,
which makes sqlx refuse every database that already applied it.

A database carrying a version this build has no migration for is refused
with `StorageError::HistoryNewerThanApp` and nothing is written, so an
older binary cannot damage a newer file. Any other migration failure is
`StorageError::HistoryMigration`.

`QueryHistory::record` refuses a query over 1 MiB with
`StorageError::TooLarge`.

`QueryHistory::prune(retention_days)` removes unpinned rows in two passes:
first anything past the retention window, then anything past
`MAX_UNPINNED_ENTRIES` (100,000), oldest first. Pinned rows survive both.
When it deleted anything it runs FTS5 `optimize`, because the delete
triggers otherwise leave tombstones that grow the index as the table
shrinks. It returns a `PruneReport { expired, over_cap }`.

### Searching the history

`QueryHistory::search_page(&HistoryQuery, HistoryPageRequest)` finds
entries that hold every search term anywhere, in any case. Each row keeps
its query lowercased by Unicode rules in `query_folded`, which SQLite's
`lower()` cannot do. Rows an older build recorded have none, and
`QueryHistory::open` folds them 500 to a transaction; a partial index on
the unfolded rows makes finding none left cost nothing. `history_search`,
an FTS5 trigram index over that column, answers a term of three
characters or more as a quoted phrase, so quotes and FTS5 operators stay
literal; a shorter term goes through `instr`.

`HistoryQuery` also narrows by connection, by `StatusFilter` and by a
start time. A cancelled run is stored with `success = 0`, so Failed leaves
it out explicitly.

A page is read by keyset on `(pinned, executed_at, id)`, newest first
with pinned entries ahead, never by offset. The request's limit is clamped
to `MAX_PAGE_SIZE` (1,000), one row past it says whether another page
exists, and `HistoryPage::next` is the `HistoryCursor` the next page
starts after. Rows recorded while the user scrolls never shift a page, and no
row shows twice. Cursors compare as the query orders rows, so the dialog
can tell whether a re-pinned entry falls in the pages already read.

### Deleting and restoring

- `delete_returning(ids)` deletes in one transaction, 500 ids to a
  statement, and returns the entries it removed. An id already gone is
  skipped.
- `restore(entries)` puts them back under their own ids, pinned as they
  were and folded again; the insert trigger indexes them. The history
  dialog deletes at once and offers Undo in a toast, which is this pair.
- `clear_all` empties the history, pinned entries included.
- `delete_for_connection` removes one connection's entries, pinned ones
  included, for a connection deleted along with its history, then runs
  `optimize` as a prune does.
- `connections_with_history` lists each connection the history holds
  under the name of its latest run, so a renamed connection shows once.

### What goes into the history

`HistoryService::record` is the one way in, for editor runs, saves and
imports. It records nothing while `save-query-history` is off, or when the
connection has no dialect, such as while its link is down. Otherwise the
dialect's `history_recording` decides, reading the SQL with the editor's own
script lexer:

- A statement that can carry a credential withholds the whole entry. Each
  engine lists its own in a `CredentialRules`: logins, roles, keys and links
  to other servers (`CREATE USER`, `CHANGE MASTER`), statements that do so
  only with a given word (`GRANT ... IDENTIFIED`), and functions or engines
  that take a password (`dblink`, `OPENROWSET`, `s3`). A routine body is
  read for the statements inside it, whether dollar-quoted or, on
  PostgreSQL, a plain string after `DO` or `AS`. The text is read every
  way the server may read it: with and without backslash escapes, and
  with each MySQL `/*!` comment run or skipped as each server version
  would.
- A string, quoted name or comment that never closes withholds it too, since
  what is inside a literal is then a guess.
- Redis commands carry a password in their arguments, so their rules read the
  command and its options rather than its words: `AUTH`, `HELLO ... AUTH`,
  `MIGRATE ... AUTH`, `ACL SETUSER`, `CONFIG SET` of a password parameter,
  `SENTINEL SET` and a script that names one of them
  ([redis.md](drivers/redis.md#the-editor)).
- MongoDB statements are read the same way, from their tokens:
  `createUser`, `updateUser`, `changeUserPassword`, `auth`, `connect`,
  `Mongo`, by name or in brackets, a `pwd`, `password` or
  `passwordDigestor` key, and a string
  holding a connection string with a password
  ([mongodb.md](drivers/mongodb.md#the-editor)).

An entry is kept whole or not at all, never rewritten to cut a secret out.
Turning the setting off keeps what is already there; Clear removes it.

## App preferences with `gio::Settings`

`data/app.tablepro.TablePro.gschema.xml.in` holds every app-wide preference and the window geometry. Meson installs it to `$datadir/glib-2.0/schemas` and compiles it; see [ADR 0007](decisions/0007-gsettings-preferences.md).

The schema id is the application id and the path follows it: `app.tablepro.TablePro` at `/app/tablepro/TablePro/` for an installed build, `app.tablepro.TablePro.Devel` at `/app/tablepro/TablePro/Devel/` for a development one. Neither reads the other's settings.

| Key | Type | Default | Range |
|---|---|---|---|
| `window-width` | `i` | `1200` | 360 to 32767 |
| `window-height` | `i` | `760` | 294 to 32767 |
| `is-maximized` | `b` | `false` | |
| `default-page-size` | `u` | `1000` | 100 to 100000 |
| `confirm-bulk-delete` | `b` | `true` | |
| `restore-session` | `b` | `true` | |
| `mcp-server-enabled` | `b` | `false` | |
| `mcp-server-port` | `u` | `23508` | 1024 to 65535 |
| `ai-provider` | enum | `none` | `none`, `anthropic`, `openai`, `openai-compatible` |
| `ai-anthropic-model` | `s` | `claude-opus-5-5` | |
| `ai-openai-model` | `s` | empty | |
| `ai-compatible-model` | `s` | empty | |
| `ai-compatible-url` | `s` | `http://localhost:11434/v1` | |
| `ai-inline-suggestions` | `b` | `false` | |
| `connect-dialog-driver` | `s` | `postgres` | |
| `save-query-history` | `b` | `true` | |
| `history-retention-days` | `u` | `30` | 0 to 365 |
| `query-timeout-secs` | `u` | `60` | 0 to 3600 |
| `use-system-font` | `b` | `true` | |
| `custom-font` | `s` | `Monospace 12` | |
| `style-scheme` | `s` | `Adwaita` | |
| `vim-keybindings` | `b` | `false` | |
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

`StorageError` is the crate's `thiserror` enum:

- Files: `Io` and `Permissions` with the path, `Write` with the path and GLib's error, `Serde`, `DocumentUnavailable` for a JSON document that cannot be used, and `DraftNotUtf8`.
- `Schema` with a reason: a Reset of a connection list that is readable, a name `DraftScope::new` refuses, or, from `tablepro-session`, a connections write task that failed.
- The history database: `Database`, `HistoryNewerThanApp`, `HistoryMigration`, and `TooLarge` for a query over the size limit.
- The saved queries: `EmptyName`, `NotFound`, and `TooLarge` for a name or query over its limit.
- `Encode` for a history CSV export.
- `NotInitialised` and `Settings` are declared, but nothing returns them: `AppSettings` returns its own `SettingsError`.

A keyring failure is a `SecretError` from `tablepro-core`, not a `StorageError`; `KeyringError::Secret` carries it. UI code matches on the variants to say something useful, never the raw `Display` text. See [error-handling.md](error-handling.md).

## Changing a format

- A JSON document is a `VersionedDocument` with a `version` field. A new shape bumps its `VERSION` and appends a step to its `UPGRADES`, which turns a file of the version before into the new shape. `decode_document` runs an older file through every step it is behind, oldest first, so a user who skipped releases keeps their data. A step that shipped is never changed or dropped.
- The upgrade happens in memory. The file stays as it was until the next save writes the current version.
- A file older than the first step, one a step cannot read, or one from a newer build is never written over. The connection list and a workspace wait for the user's Reset, which moves the file aside; the smaller state files move an unusable file aside themselves.
- Each released version of the connection list and the workspace file has a golden file that a test reads into the model it was written from: `crates/storage/tests/fixtures/connections-v1.json`, `connections-v2.json`, and `crates/app/tests/fixtures/workspace-v1.json` and `workspace-v2.json`. A committed fixture is never edited. A format change adds the new version's fixture and updates the expected models of the old ones, which now read through the upgrade.
- The history database moves forward by sqlx migration: a new timestamped file under `crates/storage/migrations/` with its own fixture test, never an edit to an applied one.
- Update this page, and add a fragment to the Linux changelog.
