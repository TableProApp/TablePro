# Storage

The app's data goes to the store its shape calls for. The core's `storage` crate owns the stores and the calls that write private files; the app crate's workspace, column-width and filter files go through those same calls in `tablepro_storage::fs`. The stores that come from the desktop, GSettings and the Secret Service, are in `tablepro-linux-platform` (`crates/platform`).

| Data | Backend | API |
|---|---|---|
| Saved connections, with their SSH and credential profiles | JSON file | `ConnectionStore` |
| Database passwords, SSH passwords and key passphrases | `oo7`: the host's Secret Service, or the Secret portal inside Flatpak | `SecretStore`, read at each connect by `KeyringCredentials` |
| The TablePro account's refresh token | the same keyring, or memory alone when none answers | `SecretStore` through the app's `KeyringRefreshToken`, a `tablepro_account::RefreshTokenVault` |
| The account's device ID and last entitlement, or an imported offline file | JSON file | `tablepro-account` ([core ADR 0016](../../core/docs/decisions/0016-tablepro-accounts.md), [ADR 0038](decisions/0038-account-page-and-license-ask.md)) |
| The usage data's anonymous ID and what it sent once | JSON file | `Telemetry` in the app crate ([ADR 0039](decisions/0039-usage-data.md)) |
| Preferences and window geometry | `gio::Settings` | `AppSettings` |
| Query history, saved queries with their folders and keywords, favourite tables and databases, and table folders | SQLite, one database ([core ADR 0017](../../core/docs/decisions/0017-favourites.md)) | `QueryHistory`, `SavedQueries`, `SavedQueryFolders`, `Favourites`, `TableFolders` |
| Team Library items, one file per server and account | JSON file | `TeamLibraryStore` |
| Editor tab text | one file per tab | `DraftStore` |
| Open tabs, open sessions, column layouts, filters, highlight rules | JSON files the app crate writes | `WorkspaceStore`, `OpenSessions`, `crates/app/src/persistence/` |

[Where files go](#where-files-go) has the paths.

## Connection metadata

`ConnectionStore` holds the saved-connection list, one store per storage root:

- `load_blocking`, `list_blocking`, `upsert_blocking`, `insert_after_blocking`, `update_blocking`, `remove_blocking`, `touch_last_opened_blocking`, the group, favourite and project operations below, `preview_import_blocking`, `apply_import_blocking` and `export_blocking` run off the GTK thread. A change holds the store's lock and an exclusive lock on `connections.json.lock` beside the list across read, change and write, and reads the file again first, so neither another thread nor another process on the same root (a second app, a hand edit, a sync tool) loses an entry to a stale copy. A lock file that cannot be made or locked (NFS without lockd, SMB) is logged and the write goes ahead on the re-read alone. A read also reads the file again, keeps the list it has when the file cannot be read, and publishes a list it finds changed. `update_blocking` changes one entry as the list holds it at the write, so a last-opened stamp from another window in between is kept.
- A write goes through `write_document_blocking` first and the cached list changes only once it landed, so a failed write leaves both as they were. The first write over a file an older build wrote keeps a copy of it first ([Copies before a format upgrade](#copies-before-a-format-upgrade)).
- A file that another version wrote in a newer format is refused; one in the same format is read and written whichever build wrote it.
- `subscribe` hands out a watch of `ConnectionListSnapshot`, so every picker sees every writer's change.
- A file that cannot be read, or that holds a format newer than this build's, leaves the store `Unavailable`, and it refuses every write until the user picks Reset (`reset_unreadable_blocking`), which moves the file aside. A file broken after the list was read is found by the next change, which refuses it the same way; a file that cannot be read at all then fails the change with `Io` and leaves the list shown. Reset reads the file first and refuses when another process already reset or rewrote it.
- A `SavedConnection` does **not** carry a password. Secrets live in the keyring, keyed by the connection's UUID, so a rename or a new host keeps them.
- `safe_mode` is the connection's Safe Mode level, the macOS app's six: `off` (Silent), `confirm_writes` (Alert), `alert_full`, `safe_mode`, `safe_mode_full` and `read_only`; the first three keep the names earlier builds wrote, and `silent` and `alert` read too. It has no default, since guessing Off would drop a guard. A session runs `SafeModeLevel::enforced`: the Full levels ask before reads and the Safe Mode levels for proof, which no app on the core does yet, so those three run as Read-Only, rounded up and never down. The Linux form and menus offer Off, Confirm Writes and Read-Only; a stored level shows as the one it runs, and saving that keeps the stored level (`SafeModeLevel::edited`).
- `external_access` is what MCP clients may do on the connection: `blocked`, `read_only` or `read_write` ([ADR 0022](decisions/0022-ai-assistant-and-mcp-server.md)). A new connection starts at `read_only`. It has no default either.
- `tls.mode` may be `verify_ca`, which macOS holds: it checks the chain and not the name, no engine offers it yet, and a connect refuses it. A form shows a mode its engine does not offer as the weakest offered one at least as strict (`TlsMode::at_least_in`), never the engine's weaker default.
- `ai_policy` is what the AI assistant may send from the connection: `ask`, `allow`, `never` or `app_default`, which follows the app's own AI setting as a macOS connection that never picked one does. A new connection starts at `ask`. It has no default either. Linux has no app default, so it shows `app_default` as Ask Each Time and a save of that keeps it (`AiPolicy::edited`).
- `query_timeout_secs` is the editor's query timeout on the connection, in seconds, with 0 for none. Left out, the connection follows the timeout in Preferences, and it is written back without one.
- The file's `groups` list is the library's folders, a tree ([core ADR 0006](../../core/docs/decisions/0006-connection-library.md)). Each `ConnectionGroup` has an `id`, a `name` (`ConnectionGroupName`, kept as written: a new or renamed group's name passes `ConnectionGroupName::new`, in a connection name's form, not empty, of any length as on macOS, no control characters; `shown` cleans a stored one for display and `same_name` compares that form), a `parent_id` (none for a top-level group), an `order` among its siblings, and an optional `color` and `icon` (`LibraryIcon`: one of the `ConnectionIcon` names, or the SF Symbol a macOS group wears, which Linux does not draw). Groups nest at most 3 levels. A new or moved group may not share a name with a sibling in any case, where a top-level group's siblings are the top-level groups of its project; an imported file can still bring two that differ only in case. A group reordered inside its own parent is checked for neither rule, so two such groups, or one a hand-edited file nests deeper than 3 levels, still reorder.
- A connection's `group_id` names its group, none for the top of the list, and its `order` is its place there. Places are kept as stored: siblings may share a number or skip one, and a list reads them by number, then in file order. A move numbers the list it changes from 0 and changes the group or parent of the moved entries only, and a new entry, or one moved to another group, goes after the last there. An edit keeps a group the list lacks when the entry was already filed there. `insert_after_blocking` saves a new entry right after another one, in that one's group, in one write; when that one is gone it is saved as `upsert_blocking` saves it. A group whose parent is missing or that sits on a cycle reads at the top (`GroupTree::parent`), and a connection whose group is missing reads at the top (`ConnectionList::group_of`, `connections_in`), while each keeps the id it was stored with: a pull can bring a connection before its group. A read keeps the first of two entries with one id.
- `create_group_blocking`, `rename_group_blocking`, `set_group_color_blocking`, `set_group_icon_blocking`, `move_groups_blocking` (to another parent, before a sibling), `delete_group_blocking`, `move_connections_blocking` (to a group, before a connection) and `move_connections_to_group_named_blocking` change the tree. Each refuses what would break it with a `StorageError` carrying a stable code: `GroupNotFound`, `GroupExists`, `GroupNameTaken`, `GroupCycle`, `GroupTooDeep`, `ConnectionNotFound`. Deleting a group deletes the groups inside it and moves their connections to the top of the list. `GroupTree::can_place` and `GroupTree::can_create_in` apply the same parent, cycle and depth rules without writing, so the app can turn off a move or a New Subgroup the store would refuse.
- The file's `projects` list holds every `ConnectionProject` ([core ADR 0067](../../core/docs/decisions/0067-connection-projects.md)): an `id`, a `name` (`ConnectionProjectName`, in a group name's form), an `order`, and an optional `color` and `icon` as a group has. No two projects share a name in any case. All Connections is no project and has no entry.
- A top-level group's `project_id` is its project, and its subgroups and their connections follow it. A connection's own `project_id` counts only while it has no group. `ConnectionList::effective_project`, `effective_group_project` and `ProjectMembership` read it that way, and ignore a `project_id` stored on a subgroup or a grouped connection. Every read and write drops a `project_id` no project holds, keeps the first of two projects with one id and numbers the projects from 0.
- `ConnectionList::scoped(project)` is the list one project shows: its connections, its groups with the empty ones, the favourites among them, and every tag and project. `None`, or an id no project holds, is the whole list. `recent` and `connections_in` of the result are the project's. The active project is each app's own per-device setting, never in this file.
- `create_project_blocking`, `rename_project_blocking`, `set_project_color_blocking`, `set_project_icon_blocking`, `move_projects_blocking` (before another project), `delete_project_blocking`, `move_connections_to_project_blocking` and `move_groups_to_project_blocking` change the projects, with the codes `ProjectNotFound`, `ProjectExists` and `ProjectNameTaken`. Deleting a project keeps its groups and connections, in no project. A connection in a group is refused with `ConnectionGrouped` and a subgroup with `GroupNotTopLevel`: the top-level group decides for both. `create_group_blocking` makes a top-level group in the project it names, and a new ungrouped connection is saved with its `project_id`.
- Every local change keeps the membership whole: a connection filed in a group drops its own `project_id`; one moved out to the top, or left there when its group is deleted, stays in the project it was in unless the change names another; a group moved under another drops its own; a subgroup moved to the top stays in the project of the top-level group it left. `apply_cloud_pull_blocking` does none of this and keeps each `project_id` it finds.
- `favorites` lists the favourite connections in their order. `add_favorites_blocking` adds or moves some before a given one, `remove_favorites_blocking` takes them off, and deleting a connection drops it. `ConnectionList::recent` is the opened connections, newest first, without the favourites.
- The Linux app's picker and the window's tree show the groups as a tree in the library's order, empty ones too, each group's subgroups above its connections. Only the Move to Group menus and the search results name a group by its path from the top, such as `Work / Staging`. The picker also has a Favourites section, in the favourites' order, and a Recent section with the last 5 connections opened, favourites left out. New Group makes a group at the top and New Subgroup makes one inside a group, up to 3 levels. Groups and connections move by drag and drop, or with Move Up and Move Down.
- The file's `tags` list holds every `ConnectionTag`: an `id`, a `name` (`ConnectionTagName`, kept as written; a new or renamed one is in a connection name's form, 1 to 32 characters, no control characters), an optional `color` from the same palette as `color` (a macOS tag can have none) and `is_preset`, set on the tags macOS starts every library with. `create_tag_blocking` and `update_tag_blocking` refuse a name another tag holds in any case with `TagNameTaken`; a library written as another app holds it can still bring two.
- A connection's `tags` are ids from that list, each once. One the list lacks reads as no tag and stays, since a pull can bring a connection before its tag; `delete_tag_blocking` takes the tag off every connection in the same write.
- `icon` is a `LibraryIcon`: one of the `ConnectionIcon` names, stored as the name's id as earlier builds wrote it, or an SF Symbol a Mac picked, stored as `{"symbol": ...}`. The app draws a named one with a symbolic icon from the theme (`crates/app/src/ui/icons.rs`) and a symbol as the default icon; the form shows a symbol as no icon and a save keeps it.
- A connection's `name` is stored as written. The form, a rename and a file import write it as `shown_name` gives it: characters that show as nothing (U+200B, U+FEFF) dropped, control characters and every other space (U+00A0, U+2007) as a plain space, no blanks around it, and in Unicode NFC, so a typed or imported name that looks like a saved one is the same name. A file import cleans tag and group names the same way, cuts a tag's to 32 characters and leaves out a group or tag whose name is blank.
- A group or tag name made only of invisible characters, which macOS accepts for a group, shows as its Unicode escapes. A new name of that kind is refused.
- An import is previewed first: `preview_import_blocking` works out every entry as it will be saved and writes nothing, the app shows each one with its host, and `apply_import_blocking` writes that result, or refuses with `ImportOutdated` when the list changed in between. For an added entry the preview also names its SSH server and a TLS mode looser than a new connection's; for an updated one, the name it had when the file renames it (`ImportChange::Updated`, `renamed_from`). An imported entry never takes a name another entry holds or held before the import, whatever order the file lists them in. An updated entry whose name the file keeps keeps it, even when another entry has the same one.
- On import, a tag is matched by id, then by name in any case, and added only when neither matches, so importing a file twice leaves one tag of each name. A tag matched by id takes the file's colour, and its name unless another tag has it. A connection updated by an import takes the file's tags and icon.
- On import, a project is matched by id, then by name in any case, the first in order when two share one, and added last otherwise. One matched by id takes the file's colour and icon, and its name unless another project has it. `preview_import_into_blocking` names the project that a new top-level group or ungrouped connection the file files under none lands in; an entry the import only updates keeps its project unless the file names one.
- On import, a group is matched by id, then by the exact name under the same parent (for a top-level group, among the top-level groups of its project), then by that name in any case among the groups the list had before the import, and otherwise added last in its place. So a file's own `Work` and `work` stay two groups, as a read of that file gives. A group matched by id keeps its place and takes the file's colour, icon, and name unless a sibling has it. Those renames come first, so a name one of them frees or takes decides how the rest match, whatever order the file lists them in. A group the file nests below the third level is not added: it and the groups under it map to the third-level group above them, so their connections land there, as macOS cuts the path. A connection updated by an import takes the file's group, going last there when the group changed; an added one keeps the file's order after the list's own. The file's favourites are added, and an import never removes one.
- An edit, a copy or a move to another group goes through the app's `SavedConnectionEditor`, which writes the keyring first. A copy is saved with `insert_after_blocking`, right after its original, as on macOS. A refused secret stops before the list changes, and the secrets of a copy whose entry did not land are deleted again. Edits and copies run one at a time, so two windows editing one connection never leave the host of one with the password of the other.

- An entry of `connections`, `groups`, `tags`, `ssh_profiles` or `credential_profiles` that this build cannot read, such as one with a value a newer build wrote or without a field that has no default, is held: it is left out of the list, written back as it was after the entries the list holds, and replaced by a readable entry with its id. The rest of the file stays usable. `ConnectionList::unreadable` names the held connections. A connection also keeps the keys it does not know (`SavedConnection::unknown`) and writes them back.
- Beyond the form's fields, a connection carries `details` (`ConnectionDetails`: `startup_sql`, `ai_rules`, `ai_allowed_tools`, `ssh_profile_id`, `ssh_route`, `credential_profile_id`, `credential_reference`, `redis_database` and the plugin's `additional_fields`) and `device` (`DeviceOnly`: `local_only`, `is_sample`, `origin`, the `password_source` file or command, and the Cloudflare, Cloud SQL proxy, SOCKS and tunnel command settings). Both sit flat in the entry. `field_trust` classes each additional field as the macOS app's `ConnectionFieldTrust` does, and `apple/scripts/ci/check-connection-field-trust.py` fails when the two tables differ.
- An export carries the connections as `SavedConnection::portable` gives them: no `device`, no unknown key, no detail that runs, sends or signs in on the reader's device, and only portable additional fields. An import takes the same from the file and keeps an updated entry's own. Neither carries the profiles.
- `ssh_profiles` holds `SshProfile`s (a name and an SSH setting) and `credential_profiles` holds `CredentialProfile`s (a name, a user, where the password comes from, the secure plugin fields and an order). They are written only through the library write below; taking one out leaves the connections that name it naming it.
- `store` is the file's `StoreIdentity` ([Store identity and the change journal](#store-identity-and-the-change-journal)).
- `replace_library_blocking(over, build, delete)` writes the whole library (`LibraryWrite { connections, groups, tags, favorites, projects, ssh_profiles, credential_profiles, removing }`) in one commit, for another app's store moving into the core: every id and value as given, nothing trimmed, checked, cleaned or placed. `over` is the SHA-256 of the file the host last checked (`None`: no file); a file that changed since is refused with `LibraryChanged`, and `build` makes the write from that same file under the same lock. What the store would otherwise drop is refused: a repeated id, favourite or tag on a connection, or an entry both kept and in `removing`, with `RepeatedId`, a favourite of no connection the file keeps with `ConnectionNotFound`. A connection or profile this build cannot read stays unless the write names its id or lists it in `removing`. An id `removing` names that the file holds as two kinds is refused with `RepeatedId`.
- A library write takes the secrets of what it removes with it, after it lands. In the same file write as the change, it lists in `secrets_to_delete` each SSH or credential profile it takes out and each connection `removing` names (`SecretOwner`: a kind and an id). The readable connections it leaves out keep their secrets for the host. Still under the write lock, it calls its `delete` for each listed owner whose id the file no longer holds for that kind, then writes the list without the ones that went. An owner the file holds again keeps its secrets. One `delete` could not clear, or one a stop left listed, goes on the next `replace_library_blocking`, after that write's digest check. The FFI's `replace_library` deletes through `HostSecrets::delete_connection` and `delete_profile`, which must not call the library while it holds the lock. A profile's host answers `Deleted`, or `NotOwned` for secrets another app keeps, as iOS answers for the Mac's: both clear the entry, and only an error keeps it listed. A build that does not know the list reads the file and leaves the list out of its next write, so those secrets can be left behind but nothing else is lost. It returns the SHA-256, in hex, of the bytes the file holds after it, and `read_library_blocking` returns the list with the SHA-256 of the bytes it was decoded from, so a host can tag exactly the bytes a write leaves and check a read's against its tag (`None` while there is no file). A read vouches for nothing.
- `rebuild_library_blocking` writes the same way for a file its host cannot vouch for: the file then holds only what the write names, profiles included, with no entry this build cannot read, and a new `StoreIdentity` generation, as a restore starts. A file this build cannot read is moved aside first (`Rebuilt.set_aside`), and the journal is told the write against nothing, so no id from the replaced file goes out as a deletion. The file's `secrets_to_delete` goes with it, unhonoured, since its ids are not vouched for, so a rebuild can leave those secrets behind.

### SSH settings

`SavedConnection.ssh` holds an optional `SavedSshConfig`:

- `enabled`, left out while it is on. A tunnel switched off keeps its settings, as macOS keeps them, and a connect does not dial it.
- `host`, plus optional `port` and `username`. Leaving them out lets `~/.ssh/config` decide.
- `jump_hosts`: one `SshJumpHost` per hop, empty for a direct connection. A hop with no id, auth or key path is stored as `[user@]host[:port]`, as earlier builds wrote one, while that text reads back as the same hop, and an entry of that form may list several hops with commas. A macOS hop adds an `id`, an `auth` (`agent` or `private_key`) and a `key_path`, and is stored as an object. A connect refuses a hop with a key of its own (`SshDestinationProblem::JumpHostKey`): OpenSSH's `-J` signs in to each hop with the agent and the SSH configuration only.
- `auth`, tagged by `kind`: `agent`, `private_key` (optional `path` and `has_passphrase`), `password`, `keyboard_interactive` or `none`, which a connect dials as `agent` since both transports try the none method first. The form shows `none` as the agent and a save keeps it.
- `kept_key_path`: the key file kept while `auth` is not a key, as the macOS form keeps it. A connect reads only the key auth's own `path`.
- `agent_socket`, `totp` (`mode`, `algorithm`, `digits`, `period`) and `remote_file` (`path`, `access`): what macOS keeps for the tunnel. A connect refuses a remote file with `ConfigError::RemoteFileOverSsh`, since only the macOS app opens one. The form shows none of these and a save keeps them (`SavedSshConfig::kept_over`), with the ids and keys of the hops it still names.
- Keys a newer build wrote inside the settings stay (`unknown`), and `TlsConfig::unknown` keeps those inside `tls`. `SshProfile` keeps its own in its `ssh`.

SSH passwords and key passphrases sit in the keyring next to database passwords. The system OpenSSH client runs every combination ([ADR 0013](decisions/0013-openssh-client-transport.md)), and asks for a missing secret through the app's prompts.

## Passwords in the keyring

`SecretStore` (`tablepro_linux_platform`) is the app's `SecretVault`: `store`, `load`, `relabel`, `delete_kind` and `delete_connection`, keyed by connection id and `SecretKind`, with the secret as a `SecretString`. It is also the app's `SecretItems`, which holds the MCP access token and the AI providers' API keys and labels them through the app's `SecretItemLabeler`.

Backed by the [`oo7`](https://crates.io/crates/oo7) crate ([ADR 0004](decisions/0004-libsecret-secret-storage.md)). Outside Flatpak it talks to the host's Secret Service over D-Bus, which GNOME Keyring and KWallet both implement. Inside Flatpak it keeps the items in oo7's encrypted file keyring in the sandbox, at the path and with the key oo7's own `Keyring::new` uses, so items saved by earlier builds still read. The store asks the Secret portal for that key itself, because ashpd's `secret::retrieve` ignores the request's Response and waits for good on a refused request. A refused request is `Locked`, a cancelled one `UnlockDismissed`; the Response gives no reason, so a missing login keyring also reads as locked. The unlock prompt the portal's backend shows has no time limit, and the store waits up to five minutes for an answer. Without the portal, the store reports `PortalUnavailable` rather than trying the Secret Service, which the sandbox cannot reach anyway.

Notes:

- Schema name: the application id plus `.Password`, so `app.tablepro.TablePro.Password` for an installed build and `app.tablepro.TablePro.Devel.Password` for a development one. Neither reads the other's secrets. Attributes: `xdg:schema`, `connection-id` and `kind` (`db_password`, `ssh_password`, `ssh_passphrase`).
- The MCP server's access token is one item of its own, with `xdg:schema` and `kind` `mcp_token` and no `connection-id`, so deleting a connection never matches it. It is made on the server's first start and replaced from Preferences.
- Each AI provider's API key is one item, with `xdg:schema`, `kind` `ai_api_key` and `provider` (`anthropic`, `openai` or `openai-compatible`) and no `connection-id`. Preferences > AI stores and removes it; the assistant reads it before each request.
- The TablePro account's refresh token is one item, with `xdg:schema` and `kind` `account_refresh_token` and no `connection-id`. The server rotates it on every refresh, and each one replaces the item. Sign-out deletes it. When no keyring takes it, it lives in memory until the app quits and the next launch starts signed out; the item the keyring held before is deleted then, since the server refuses a rotated token.
- Labels name the kind and the target, for example `TablePro database password for app@db.example.com:5432/shop`, so the item is identifiable in Seahorse on a host install. Under Flatpak the items sit in the app's own file keyring.
- The store unlocks the keyring and the item before reading. A locked keyring otherwise looks exactly like a connection with no saved password.
- Failures are typed (`SecretError`): a dismissed prompt, a locked keyring, a missing service, a missing portal and a bad encoding each get their own message and their own next step.
- With no Secret Service on the host, or no Secret portal inside Flatpak, the store reports `ServiceUnavailable` or `PortalUnavailable` and the UI prompts at connect time. The app never writes passwords to a plain file as a fallback.
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
3. Everything kept for it: column layouts, filters, highlight rules, the saved tabs with any
   copy Reset moved aside or an upgrade kept, the editor drafts
   (`WorkspaceStore::purge`), the saved queries, and the query history when
   the user turned that on. A
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

## Store identity and the change journal

Each store carries a `StoreIdentity`, a `generation` and a `sequence` ([core ADR 0054](../../core/docs/decisions/0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md), The engine), which sync keeps beside its bases:

- `connections.json` and a Team Library file keep it as `store`. A file without one, as an older build writes it, gets a new generation at its next write.
- `history.db` keeps it in the one row of `store_identity`, made when the database opens. A trigger on each table that syncs (`history`, `saved_queries`, `saved_query_folders`, `favourite_tables`, `favourite_databases`, `table_folders`, `table_folder_items`) raises the sequence on every insert, update and delete, whichever process makes it. Trimming an upgrade copy puts its sequence back.
- Every write keeps the generation and raises the sequence. `StoreIdentity::compared_with` tells sync whether the store continues, is another generation (restored, replaced or copied in) or went back (an older copy). Both of the last two put its kinds into refill. A host that restores a store from a backup of its own calls `start_new_generation`; Reset of an unreadable connection list starts one with the next write.
- Each store's write path tells a `ChangeJournal`, once per commit, after the write and outside every lock the store holds, a `JournalEntry` for each kind the commit changed with the records it wrote and the records it deleted ([core ADR 0060](../../core/docs/decisions/0060-the-change-journal-names-the-records-each-write-changed-and-a-store-is-one-file.md)). A `RecordRef` names a record as its store does: a UUID (a saved query, folder or history entry by its `record_id`), a Team Library item by its team and client id, the table a favourite or a table folder item names, or a favourite database. A favourite's place change writes its connection. `set_journal` on `ConnectionStore`, `QueryHistory` (for every handle it gives out) and `TeamLibraryStore` sets it. A write that changes nothing tells nothing.

## Table folders

`QueryHistory::table_folders` gives the folders a person files a connection's tables in, per database and schema (`table_folders`), and the table each file names (`table_folder_items`, one folder per table). Ids are UUIDs, times whole milliseconds. No foreign key joins them: an item whose folder is missing reads as unfiled. `put` keeps a folder's own id and times, deleting a folder takes its items with it, and `SavedQueries::delete_for_connection` takes a deleted connection's folders and items with its saved queries and favourites.

## Team Library

`TeamLibraryStore` keeps one account's Team Library items, per team, at `$XDG_STATE_HOME/<dir>/team-library/<digest>.json`, the digest a SHA-256 over a fixed label, the server's API origin and the account id, so a server's id never names a path. The file records its owner, and a file bound to another one is refused with `StoreOwnerMismatch`. An item is its kind (`connection`, `folder` or `query`), the client id the team stores, byte for byte, and its fields as a JSON object the store does not read.

## Where files go

`tablepro_storage::StoragePaths` resolves every directory once at startup
through GLib, so the app agrees with the rest of the desktop about the
[XDG base directories](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
and their fallbacks. Under Flatpak they resolve inside the sandbox, and
nothing reaches outside it.

| Accessor | Path |
|---|---|
| `connections_file()` | `$XDG_CONFIG_HOME/<dir>/connections.json` |
| `column_layouts_file()` | `$XDG_CONFIG_HOME/<dir>/column_layouts.json`: each table's column layout (order, hidden columns, widths the user set) |
| `filter_settings_file()` | `$XDG_CONFIG_HOME/<dir>/filter_settings.json`, version 2: each table's filter, and the schemas each connection's sidebar lists, per database. Version 1 had no sidebar filters |
| `highlight_rules_file()` | `$XDG_CONFIG_HOME/<dir>/highlight_rules.json`: ordered rules for each table |
| `history_database()` | `$XDG_STATE_HOME/<dir>/history.db` |
| `workspaces_dir()` | `$XDG_STATE_HOME/<dir>/workspaces`: one file per session, and `open-sessions.json`: the sessions open at the last quit as `windows`, one list of keys per window, windows in the order of their first recorded session and keys in the order each window adopted them |
| `drafts_dir()` | `$XDG_DATA_HOME/<dir>/drafts` |
| `snippets_dir()` | `$XDG_DATA_HOME/<dir>/snippets`: the user's SQL editor snippets, made when Preferences opens it ([README](../README.md#snippets)) |
| `crashes_dir()` | `$XDG_STATE_HOME/<dir>/crashes`: crash reports ([error-handling.md](error-handling.md#crashes)) |
| `telemetry_file()` | `$XDG_STATE_HOME/<dir>/telemetry.json`: the usage data's random `anonymous_id`, the account PostHog knows the install as (`identified`), the day `app_opened` last went out (`opened_on`) and the events sent once per install (`sent_once`). Written only by a build with a PostHog key, once the user shares usage data |
| `account_file()` | `$XDG_STATE_HOME/<dir>/account.json`, version 1: the `device_id` this machine has on the TablePro account, the last `entitlement` token, which is signed and verified again on read, and the `account_id` it names, kept once the token expires so an offline file of another account is still refused. `offline_only` marks an offline file imported with no sign-in: the launch then never opens the keyring, and a file that no longer verifies is removed. A file of another version reads as empty, and the device is registered again. Sign-out removes it. Without it, a launch never opens the keyring for the account |

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
- `write_private_blocking` writes a 0600 temporary file beside the target,
  syncs it, renames it over the target and syncs the directory: a reader
  sees the old file or the new one, never a mix, and the new one survives
  a power cut. The rename replaces a symbolic link rather than its target,
  and the new file is 0600 whatever mode the old one had.
- `append_private_blocking` appends to a file it creates 0600 when absent,
  for the crash report, which a second panic adds to.
- `document::write_document_blocking` encodes a versioned document and
  writes it with `write_private_blocking`, after keeping a copy of a file
  an older build wrote ([Copies before a format upgrade](#copies-before-a-format-upgrade)).
  Every store writes its documents through it.
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

`core/crates/storage/migrations/` holds the schema as sqlx migrations, embedded
at compile time with `sqlx::migrate!` and run by `QueryHistory::open`.
`20260914000000_create_history.sql` creates the `history` table with
`query_folded`, the trigram index `history_search` over it,
`history_page_idx` on `(pinned DESC, executed_at DESC, id DESC)` for
paging, and the `saved_queries` table. Favorites metadata, ordering, coherent reads
and mutation notifications follow [core ADR 0017](../../core/docs/decisions/0017-favourites.md).

`20261126000000_record_ids.sql` gives each saved query, folder and history entry
the id it syncs under ([core ADR 0052](../../core/docs/decisions/0052-synced-records-have-canonical-ids.md)):

- `record_id` is a random UUIDv4 kept as lower-case text. The store's API names a
  query or a folder by it; a history entry keeps its integer `id` for what never
  leaves the device, which the full-text index joins on and pages, pins and the
  upgrade copies use.
- A folder's parent and a query's folder are record ids with no foreign key, and
  no synced table has a referential action: deleting a folder deletes the folders
  under it and moves their queries to the top in the store's own code. A
  reference nothing answers to reads as the top level.
- A query or a folder with no connection shows in every connection. A
  connection's list and snapshot hold those too, and deleting a connection's data
  keeps them.
- Names stay unique among one connection's queries, or among those with none;
  folder names among one connection's folders under one parent, or none. A
  keyword is unique among every query that shows where its query shows.
- Saved queries and folders keep `created_at` and `updated_at` in whole
  milliseconds.
- `SavedQueries::put` and `SavedQueryFolders::put` write records a pull or
  another store brings under their own ids. Where two meet in one place under
  one name or keyword, the one created first keeps it, then the lowest id; each
  other takes the first free `<name> (2)` or loses its keyword, as an edit of
  this device's own.
- A put stores a folder name in the form the list shows and a keyword as
  `set_keyword` keeps it, since the unique indexes compare the stored text; a
  keyword a local save refuses is cleared. Names keep their first 200
  characters. A folder cycle the batch closes sends its folder created last to
  the top, and a folder 64 levels deep or more goes to the top too. Each such
  change is an edit of this device's own.

**An applied migration is never edited.** Each change is a new timestamped
file with its own fixture test. Editing one in place changes its checksum,
which makes sqlx refuse every database that already applied it.

A database carrying a migration this build does not have is refused with
`StorageError::HistoryNewerThanApp` and nothing is written, so a build never
changes a schema newer than its own. A database at the same schema is read
and written by any build. Any other migration failure is
`StorageError::HistoryMigration`.

Before a migration runs on a database that already has some, `open` keeps a
copy of it ([Copies before a format upgrade](#copies-before-a-format-upgrade)).

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
`lower()` cannot do, so the app writes it. `history_search`,
an FTS5 trigram index over that column, answers a term of three
characters or more as a quoted phrase, so quotes and FTS5 operators stay
literal; a shorter term goes through `instr`.

`HistoryQuery` also narrows by connection, by a list of connections
(`connections`, a project's, bound as one JSON array so its size meets no
limit), by `StatusFilter` and by a
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
- A deletion the user asks for (`delete_returning`, `clear_all`,
  `delete_for_connection` and the saved queries' `delete` and
  `delete_for_connection`) reaches each copy an upgrade kept before the
  database, so a copy that fails leaves the database as it was and an Undo
  never loses its entries. `prune` trims the copies after its own deletes.
  Either way `trim_upgrade_copies` also makes each copy hold no history entry
  or saved query the database no longer has. It
  attaches the database and deletes the rest in one transaction with
  `secure_delete` on, optimizing the copy's full-text indexes, so the words
  leave its blocks and freed pages together. A copy that cannot be trimmed,
  being damaged, is deleted, and so is what a crash left of one: an unfinished
  copy, a temporary file and the journals of a copy that is gone.
- `connections_with_history` lists each connection the history holds
  under the name of its latest run, so a renamed connection shows once.
  `connections_with_history_in` keeps the list to the connections it is
  given, and `SavedQueries::list_for` lists the saved queries of a set of
  connections, as a project's views need.

### Following the saved queries

The Favorites sidebar and Saved Queries dialog follow the shared revision
feed from one `QueryHistory` ([core ADR 0017](../../core/docs/decisions/0017-favourites.md)).
A write from any window, an import or a deleted connection refreshes every list.
The sidebar reads queries and folders as one snapshot. Each list rejects replies
from an older read. Selection and folder expansion stay with their record IDs
during a refresh and clear when the front connection changes. Confirmed saves,
renames, moves and deletions hold the process until the write finishes.

The editor first inserts without replacement and asks for confirmation if the
name is taken. Confirmed replacement keeps the query's record id. The existence check
and write share a transaction, so simultaneous saves report which one
replaced the query. Renames update only the stored name and modification
time, leaving newer SQL and the connection identity intact.

Unsaved database files use a UUID derived from their canonical URI, so queries
stay in the same scope after reopening the file. Queries saved by older builds
with a temporary file identity remain available in the Saved Queries dialog.

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
  PostgreSQL, a plain string after `DO` or `AS`. So is every string of a
  script that hands the server text to run (T-SQL `EXEC` and
  `sp_executesql`, MySQL `PREPARE ... FROM` and `EXECUTE IMMEDIATE`,
  PL/pgSQL `EXECUTE`) or stores a string in a T-SQL or MySQL `@` variable,
  since the text may reach them through a variable, in this run or a later one.
  On SQL Server a named argument whose name holds `password`, `passwd` or `pwd`
  withholds the entry whatever the procedure. The text is read every
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

`data/app.tablepro.TablePro.gschema.xml.in` holds every app-wide preference, the window geometry and the newest release that has run. Meson installs it to `$datadir/glib-2.0/schemas` and compiles it; see [ADR 0007](decisions/0007-gsettings-preferences.md).

The schema id is the application id and the path follows it: `app.tablepro.TablePro` at `/app/tablepro/TablePro/` for an installed build, `app.tablepro.TablePro.Devel` at `/app/tablepro/TablePro/Devel/` for a development one. Neither reads the other's settings.

| Key | Type | Default | Range |
|---|---|---|---|
| `window-width` | `i` | `1200` | 360 to 32767 |
| `window-height` | `i` | `760` | 294 to 32767 |
| `is-maximized` | `b` | `false` | |
| `sidebar-width` | `d` | `280` | 220 to 1200, in sp: the most the sidebar takes |
| `default-page-size` | `u` | `1000` | 100 to 100000 |
| `show-alternate-rows` | `b` | `true` | |
| `show-row-numbers` | `b` | `true` | |
| `grid-use-system-font` | `b` | `true` | |
| `grid-font` | `s` | `Monospace 10` | |
| `show-invisible-characters` | `b` | `true` | |
| `grid-wrap-text` | `b` | `false` | What a new tab's grid opens with; an open tab keeps its own |
| `auto-show-inspector` | `b` | `false` | |
| `row-copy-format` | `s` | `rows` | rows, rows-headers, json, csv, csv-headers, markdown |
| `default-sort` | `s` | `none` | `none`, `primary-key`, `first-column` |
| `default-sort-direction` | `s` | `ascending` | `ascending`, `descending` |
| `date-format` | `s` | `iso` | iso, iso-date, us-long, us-short, eu-long, eu-short; display only, copy and export retain original values |
| `grid-row-height` | `s` | `normal` | compact, normal, comfortable, spacious |
| `null-display` | `s` | `NULL` | Displayed as at most 20 characters, without control characters; blank uses NULL |
| `confirm-bulk-delete` | `b` | `true` | |
| `restore-session` | `b` | `true` | |
| `active-project` | `s` | empty | The id of the project the lists show; empty, or an id no project has, is All Connections ([core ADR 0067](../../core/docs/decisions/0067-connection-projects.md)). Per device, never in `connections.json` |
| `last-seen-version` | `s` | empty | |
| `share-usage-data` | `b` | `true` | |
| `usage-days` | `u` | `0` | |
| `last-usage-day` | `s` | empty | `YYYY-MM-DD` |
| `license-ask-day` | `s` | empty | `YYYY-MM-DD` |
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
| `csv-sanitize-formulas` | `b` | `false` | |
| `csv-delimiter` | enum | `comma` | comma, semicolon, tab, pipe |
| `csv-quote` | enum | `if-needed` | always, if-needed, never |
| `csv-line-break` | enum | `lf` | lf, crlf, cr |
| `csv-decimal` | enum | `period` | period, comma |

`tablepro_linux_platform::AppSettings` wraps it in typed accessors:

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

High-churn keyed data stays in files: column layouts, per-table filters, highlight rules and workspace tabs are unbounded maps, which is not what GSettings is for.

## Table state

Column layouts, filters and highlight rules use the session identity from `WorkspaceFileName`: a saved connection UUID, that UUID plus a digest of the sibling database name, or a digest of the canonical file URI. Existing saved UUID keys keep their spelling. A schema and table name complete the key. Opening a file again uses the same key; tables with the same name in different databases stay separate. Deleting a saved connection also removes its sibling database keys.

`StateFile` holds these small versioned documents in memory and writes the latest snapshot through the core's `LatestWinsWriter` and `write_document_blocking`. `flush` waits for a write attempt and returns its failure. A failed write keeps the latest state in memory. Each window shows a notice with Retry, which writes that latest state again. A successful write dismisses the notice. Closing the last window waits until every pending settings edit is saved. It checks again after workspace prompts, so concurrent window closes cannot skip the check. If local changes cannot be saved, it offers Retry, Keep Open or Close Without Saving. Consent to close without saving applies only to the settings revision shown. Newer or unreadable files stay protected and offer no write retry. An untouched protected file does not prevent closing.

Highlight rules are restored before the table grid starts reporting edits. A query result has no table identity, so its rules live only until the next run. The grid behavior is in `../ARCHITECTURE.md`, Highlight rules.

## Errors

`StorageError` is the crate's `thiserror` enum:

- Files: `Io` and `Permissions` with the path, `Write` with the path and GLib's error, `Serde`, `DocumentUnavailable` for a JSON document that cannot be used, with a code for each `DocumentProblemKind` (`storage.document_unreadable`, `_corrupt`, `_missing_version`, `_unsupported_version`, `_newer_version`, `_upgrade_failed`), and `DraftNotUtf8`.
- `Schema` with a reason: a Reset of a connection list that is readable, a name `DraftScope::new` refuses, or, from `tablepro-session`, a connections write task that failed.
- The history database: `Database`, `HistoryNewerThanApp`, `HistoryMigration`, and `TooLarge` for a query over the size limit.
- The saved queries: `EmptyName`, `NotFound`, and `TooLarge` for a name or query over its limit.
- `Encode` for a history CSV export.
- `NotInitialised` and `Settings` are declared, but nothing returns them: `AppSettings` returns its own `SettingsError`.

A keyring failure is a `SecretError` from `tablepro-core`, not a `StorageError`; `KeyringError::Secret` carries it. UI code matches on the variants to say something useful, never the raw `Display` text. See [error-handling.md](error-handling.md).

## Changing a format

- A JSON document is a `VersionedDocument` with a `version` field. Every document starts at version 1 with no upgrade step: builds before the first release left no format to read ([ADR 0033](decisions/0033-no-compatibility-with-pre-release-states.md)). A new shape bumps its `VERSION` and appends a step to its `UPGRADES`, which turns a file of the version before into the new shape. `decode_document` runs an older file through every step it is behind, oldest first, so a user who skipped releases keeps their data. A step that shipped is never changed or dropped.
- One exception: an optional field marked `#[serde(default, skip_serializing_if = ...)]` keeps the version. A file without it reads as before, and an older build reads a file with it and drops the field, while a bumped version would make that build refuse the file. The workspace file's editor tab took `database`, then `name`, `ordinal` and `untitled` this way, and the connection list took `projects` and `project_id`: a build before them drops the project list and every membership on its next write, which is its next connect ([core ADR 0067](../../core/docs/decisions/0067-connection-projects.md)).
- The upgrade happens in memory. The file stays as it was until the next save, which keeps a copy of it and then writes the current version ([Copies before a format upgrade](#copies-before-a-format-upgrade)).
- A file older than the first step, one a step cannot read, or one in a format newer than the build's is never written over. The connection list and a workspace wait for the user's Reset, which moves the file aside; the smaller state files move an unusable file aside themselves.
- Each released version of the connection list and the workspace file has a golden file that a test reads into the model it was written from: `core/crates/storage/tests/fixtures/connections-v1.json` and `crates/app/tests/fixtures/workspace-v1.json`. Once a release ships it, a fixture is never edited. A format change adds the new version's fixture and updates the expected models of the old ones, which then read through the upgrade.
- The history database moves forward by sqlx migration: a new timestamped file under `core/crates/storage/migrations/` with its own fixture test, never an edit to an applied one.
- Update this page, and add a fragment to the Linux changelog.

## Copies before a format upgrade

A file an older build wrote is copied beside itself before the first write
that replaces it with a newer format ([core ADR 0012](../../core/docs/decisions/0012-copies-before-a-format-upgrade.md)):

- The copy is `<file>.v<version>-<unix seconds>`, with `-<n>` after it for a
  second copy in the same second, such as `connections.json.v1-1762300000`.
  `<version>` is the format the copy
  holds, the document's `version` or the history's newest migration.
- `tablepro_storage::upgrade_copies` makes them. A JSON document's copy is its
  bytes as read, written 0600 by `write_private_blocking`; a copy whose bytes
  match the newest one is not made again. The history's is `VACUUM INTO` through
  the open connection, so it holds what the WAL holds too, into a `.partial`
  name that is free: macOS 27's SQLite refuses any file already there, even an
  empty one. SQLite creates it from the umask in the 0700 folder, and it is set
  to 0600 right after. Its full-text indexes are then optimized with `secure_delete`
  on, since `VACUUM INTO` copies the words of entries deleted before, and only
  then is it synced and renamed into place.
- Each file keeps its newest 3 copies (`KEPT_PER_FILE`); a new one deletes the
  oldest past that.
- A copy of a session's tabs names their editor drafts and holds none of their
  text. Drafts have no format version, so the older build reads them as they
  are now; a tab closed since the copy comes back without its text.
- Every write of the connection list first takes the connections it no longer
  has out of each copy of `connections.json`, and deletes a copy it cannot
  read that way; a failed trim fails the write, so the next one tries again. Deleting
  a connection deletes the copies of the column layout, filter and highlight rule files, which
  name its tables and values.
- A copy that cannot be made fails the write or the open, and the file is
  left as it was. The error names the copy's path.
- Reading never makes a copy. Nothing restores one on its own:
  [troubleshooting.md](troubleshooting.md#after-a-downgrade) has the steps.
- `upgrade_copies` tests the hook with a synthetic version bump of a document
  and of a migration list, so it needs no format the app shipped.
