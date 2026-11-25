# 0052: Synced records have canonical ids; saved queries and folders have UUIDs and may have no connection

- **Status**: Accepted
- **Date**: 2026-11-25

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) (Data model, Record ids) takes a record id from the CloudKit record name after its type prefix, so a move from iCloud keeps every id. The server compares record ids as bytes and reads no field. What it left open:

- **Case.** Swift's `uuidString` and the core's CloudKit mapping write a UUID in upper case (`storage/src/cloudkit/values.rs`). The core's stores write it in lower case, in `connections.json` and in `history.db`. Team Library gives a new item its UUID in lower case (`TeamLibraryID.of`, 0.88 and later) and keeps an existing item's client id as the team stores it, in whatever case `/v1` received it.
- **Ids nobody stores.** A favourite table, a favourite database and a table folder item have no id of their own. The Mac hashes what each one names (`FavoriteTablesStorage.syncId`, `FavoriteDatabasesStorage.syncId`, `TableFolderItemKey.syncId`). Since 0.77 a favourite table whose names hold `|` or `\` has an escaped id and a legacy alias, and the Mac writes both. Settings records are named by their category, `theme.<id>` or `columnLayout.<table key>`.
- **The core's saved queries.** [0017](0017-favourites.md) gave saved queries and folders `INTEGER` ids and a required connection, and a folder's subfolders go with it through `ON DELETE CASCADE`. The Mac's `SQLFavorite` and `SQLFavoriteFolder` have UUIDs and an optional connection: one without a connection is in every connection. An integer is unique on one device only, and a pulled query names a folder this device may not have yet.
- **History** is keyed by an `INTEGER` rowid that its full-text index joins on (`content_rowid='id'`). The Mac's history entries have random UUIDs.
- Envelopes and key objects ([0056](0056-end-to-end-keys-per-account-and-device.md)) are records too, and need ids that two writers of one secret or one key version cannot both create.

## Decision

Every synced kind has one id form, fixed below, that every device computes the same way for CloudKit and for TablePro Sync; saved queries and folders get UUID record ids and may have no connection, and query history gets a random UUIDv4 record id.

### Every id

- A record id meets the syntax of [0051](0051-sync-protocol-and-record-rules.md) (Kinds) and is compared as bytes. Nobody normalizes or case-folds it.
- A UUID in a record id is 8-4-4-4-12 hexadecimal digits in upper case, as `uuidString` writes it. The team library's kinds are the one exception (Team scope, below).
- A field that names another record carries that record's id in the same form, as the CloudKit fields already do.
- A device gives a new entity a new UUIDv4. A pulled record keeps its id, and so does one that the Mac's or the iOS app's own store brings into the core.
- Stores keep ids in their own form, a `Uuid` or lower-case text. The core's record rules (`tablepro-records`, 0054) write the wire form.
- **Long ids.** When a kind's CloudKit prefix plus its id passes 255 UTF-16 code units, the id is `sha256-` followed by the lower-case hex SHA-256 of the id's UTF-8, as `SyncRecordType.recordName(for:)` computes it. A kind CloudKit does not carry uses an empty prefix. A `sha256-` id cannot be read back, so the record's fields carry what it names (the settings `category`, a favourite's connection and names), and a client matches a pulled id against the ids it computes for what it holds.
- A pulled record whose id is not in its kind's form stays unapplied and is logged. Nothing stores it under another id.
- A kind added later names its records with one of these forms.

### Ids per kind

| Kind | Scope | CloudKit prefix | Id | Example |
|---|---|---|---|---|
| `connection` | personal | `Connection_` | The connection's UUID | `6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44` |
| `group` | personal | `Group_` | The group's UUID | `E6C12C96-3CBD-4A0E-9F41-E36B47F35D84` |
| `tag` | personal | `Tag_` | The tag's UUID | `84BC7D00-A144-4C18-80C0-A11C6070D4F9` |
| `ssh_profile` | personal | `SSHProfile_` | The profile's UUID | `3FD0B191-5CF8-4760-84A9-92779983F3CF` |
| `credential_profile` | personal | `CredentialProfile_` | The profile's UUID | `C00996E7-3992-4501-99A1-03CF155AB59A` |
| `saved_query` | personal | `Favorite_` | The query's UUID | `E9BFE8BE-525F-4F8A-9E9C-F795A5F09A8B` |
| `saved_query_folder` | personal | `FavoriteFolder_` | The folder's UUID | `380CB783-4B26-48F3-8F84-1468967A9FA3` |
| `table_folder` | personal | `TableFolder_` | The folder's UUID | `3D7F338F-27B8-4E35-9CFA-C88CE07131EF` |
| `connection_project` (#4376) | personal | `Project_` | The project's UUID | `CBCAF15E-97D4-4B75-8D5D-01D586CADC97` |
| `favourite_table` | personal | `FavoriteTable_` | Derived ids, below | `689915518ef07ed442508df9d8938612b7835aaef1759e217a9a1f0ec1527bfd` |
| `favourite_database` | personal | `FavoriteDatabase_` | Derived ids, below | `cdf7849ae0e1748faad83bd8417480daac3b3b322224f4aeefd1977345b7f979` |
| `table_folder_item` | personal | `TableFolderItem_` | Derived ids, below | `689915518ef07ed442508df9d8938612b7835aaef1759e217a9a1f0ec1527bfd` |
| `macos_settings` | personal | `Settings_` | The category: `general`, `appearance`, `editor`, `dataGrid`, `history`, `tabs`, `keyboard`, `ai`, `notifications`, `formatter`, `valueColors`, `customSlashCommands`, `theme.<theme id>` or `columnLayout.<table key>` | `editor`; `columnLayout.6F1C2A9E%2D0B4D%2D4C8E%2D9A51%2D3D7E2B1F0C44.shop.public.orders` |
| `ios_settings`, `linux_settings`, `windows_settings` | personal | none | A category that platform's settings registry in the core names | `editor` |
| `history_entry` | history | none | A random UUIDv4 | `07D0575D-F499-463A-AB54-2852D631B0B4` |
| `secret_envelope` | personal, team | none | Secret envelopes, below | `connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/password` |
| `key.*` | personal, team | none | Key objects, below | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/3` |
| `library_connection`, `library_folder`, `library_query` | team | none | Team scope, below | `6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44` |

The examples share the connection `6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44` and its table `shop.public.orders`. A `columnLayout` category for an SQLite file deep in the file system passes the limit and takes the long form, `sha256-` and 64 hex digits.

### Derived ids

- The hex is the lower-case SHA-256 of the UTF-8 bytes. A UUID inside is upper-case text, whatever form the store keeps it in. Names are hashed as the catalog gives them, never normalized. An absent database or schema is the empty string.
- **The escaped path** (`IdentityPath.joined`): each component with `\` written as `\\`, then `|` as `\|`, joined with `|`.
- **A favourite table.** Its components are the connection's UUID, the database, the schema and the table's name.
  - When no component holds `|` or `\`, the id is the hex of the components joined with `|`.
  - Otherwise it is the hex of `escaped|` followed by the escaped path escaped once more, which is `IdentityPath.joined(["escaped", path])`. For a table `a|b` the input is `escaped|6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44\|shop\|public\|a\\\|b`, and the id is `29fdd9a09689bcc75f08b364f5c921e2552ad3aa817a962716ad07112ca11f1e`. The hex of the plain join, `14528d9753758a53d821e91074850e8944b2ffb58c31fb7bb145a98038f1df1d`, is the legacy alias Macs before 0.77 wrote.
  - On CloudKit the core does what the Mac does: while one entry claims an alias, the entry is written and deleted under both ids, and a pulled deletion under the alias removes the entry only when exactly one entry claims it. TablePro Sync carries the escaped id only.
- **A favourite database.** The hex of the connection's UUID, `|` and the database, with no escaping, since the UUID has a fixed length and holds no `|`. The environment is not in it, so filing a database under another environment keeps its record.
- **A table folder item.** The hex of the escaped path of the connection's UUID, the database, the schema and the table's name. It has no alias. For a table whose names need no escaping it equals that table's favourite id; the kinds differ, so the two records never meet.
- **`columnLayout.<table key>`.** The connection's UUID, the database, the schema and the table, each percent-encoded as Foundation's `addingPercentEncoding(withAllowedCharacters: .alphanumerics)` does it, joined with `.`. That method ignores allowed characters outside ASCII, so every UTF-8 byte except an ASCII letter or digit becomes `%` and two upper-case hex digits, the UUID's hyphens included.
- **`theme.<theme id>`.** A user theme's id is the `id` its theme file declares, byte for byte, which the Mac's theme catalog keys it by (`ThemeCatalog.syncCategories`). The file's name plays no part.

### Secret envelopes

- An envelope's id is its parent record's kind, the parent's record id and the secret kind, joined with `/`, such as `connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/ssh_key_passphrase`, `library_connection/6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44/password` or `macos_settings/ai/ai_key.<provider id>`.
- 0056's envelope table (Envelopes and history) lists the secret kinds and their parents. A kind holds no `/` (0051, Kinds), and a secret kind holds none either: a plugin field whose id has one does not sync. So the parent's id is what lies between the first and the last `/`.
- One secret of one record has one envelope, so two devices that seal it at once meet on one id. The write is conditional on its change tag, so the second push conflicts, and that device pulls the key objects and seals again on the stored tag ([0051](0051-sync-protocol-and-record-rules.md), Conflict rules).

### Key objects

- A key object's id is its parts joined by `/`, in the order below. A part is a UUID in the form above, a decimal version with no leading zero, or a name of lower-case ASCII letters, digits and `-` that starts with a letter.
- 0056 (What the server stores and checks) says what each part means and who writes each kind, and 0051 which writer each is bound to and what each body holds. Every key kind is create-only. Here is how the parts are written.

| Kind | Id | Example |
|---|---|---|
| `key.account` | `<account>/<av>` | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/1` for the genesis; `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/4` |
| `key.device` | `<account>/<key device>/<av>`, the key device id the device drew with its device keys, not its device row's id | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4` |
| `key.recovery` | `<account>/<av>` | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/4` |
| `key.reset` | `<account>/<reset id>`, a random UUIDv4 per attempt | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78` |
| `key.cancel` | `<account>/<reset id>`, the reset it cancels | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78` |
| `key.request` | `<request id>` | `5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357` |
| `key.sas` | `<request id>/<step>`, the step `nonce`, `reveal` or `cancel` | `5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357/nonce` |
| `key.version` | `<owner>/<purpose>/<version>`, the owner the account for the purposes `personal` and `history` and the team for `team` | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/history/2`; `019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5` |
| `key.wrap` | `<owner>/<purpose>/<version>/<recipient type>/<recipient id>/<recipient version>`. The purpose `account` or `trust`, with the version the `av` and the recipient a `device`, named by its key device id, at that `av`; or `personal`, `history` or `team`, with the recipient an `account` at its `av` | `019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/account/4/device/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4`; `019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5/account/019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2` |
| `key.ring` | `<owner>/<purpose>/<version>` | `019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5` |
| `key.member` | `<account>/<av>` | `019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2` |

- One id per version, recipient, step or reset, so two writers of one meet on one id, and the create-only rule ([0051](0051-sync-protocol-and-record-rules.md)) keeps the first. Every approval takes a new key device id, so a device approved again, after Sign Out or a lock, never meets its earlier certificate's or wraps' ids at the same `av`.
- Where the bound writer is an account the id names, the server compares that part as bytes with the caller's account id in upper case: the account of `key.account`, `key.device`, `key.recovery`, `key.reset`, `key.cancel` and `key.member`, and the owner of a personal `key.version`, `key.wrap` or `key.ring`. A mismatch is refused with `writer_bound`.
- A key kind added later writes its parts the same way.

### Team scope

- `library_connection`, `library_folder` and `library_query` keep the client id the library stores, byte for byte and in its case. Shipped Macs hold unsent edits under that exact id and push them through the facade, and the library's move into the record store (0051) copies ids unchanged.
- A device that adds an entity to a team takes the stored id of the record of that kind whose id matches the entity's UUID when both are lower-cased. With none, it takes the UUID in lower case, as `TeamLibraryID.of` gives it.
- `parent_client_id`, `folder_client_id` and `connection_client_id` match a record id when both are lower-cased, as `TeamLibraryID.same` matches them.
- Within one team, no two records of one of these kinds have ids that match when lower-cased, tombstones included. The server refuses a create that would make such a pair, through `/v2/sync` and the facade alike, with `id_case_collision`. For a pair written before that, a client applies neither record, resolves no reference to either, and logs it: picking one would let a member's tombstone on the other hide a live record.
- Any other kind in a team scope follows the rules above.

### Saved queries, folders and history in the core

- **Ids.** `saved_queries` and `saved_query_folders` gain a `record_id` UUID. The `INTEGER` key stays as the SQLite rowid, inside the store. The store's API, the FFI and the apps name a query or a folder by its UUID.
- **References.** A folder's parent and a query's folder are record ids, with no foreign key. A pull can bring a query before its folder. A reference nothing answers to reads as the top level, as the Mac's `FavoritesTreeBuilder` draws it.
- **No connection.** `connection_id` is optional. A query or a folder without one is in every connection.
- **Unique places**, each compared as the store compares it today (0017):
  - a query's name among the queries with the same connection, or among those with none;
  - a folder's name among the folders with the same parent and the same connection, or none;
  - a keyword among a connection's queries and those with no connection, and a keyword with no connection among all queries, since it expands in every connection, as the Mac's save check has it.
- **Collisions.** A pull, a move from iCloud or the Mac's store moving into the core can put two records in one place under one name or one keyword. Every device settles it the same way:
  - The record created first keeps the place: the earliest `created_at`, then the lowest id compared as bytes, as `SavedQueryKeywordResolver.holdsKeywordFirst` orders them.
  - `created_at` is kept in whole milliseconds since the Unix epoch, the precision a CloudKit date keeps, so every device compares the same value. The core's store keeps whole seconds today and moves to milliseconds with the record ids.
  - Each other record loses the keyword, or takes the first free name of `<name> (2)`, `<name> (3)` and on, in that order.
  - The device writes the cleared keyword or the new name as its own edit, so it syncs, as the Mac pushes a released keyword today. Two devices that write the same value meet no conflict.
- **Deletes.** No synced table has `ON DELETE CASCADE` or `ON DELETE SET NULL`. Deleting a folder deletes its subfolders and moves its queries to the top in the store's own code (0017), so every row it changes is a write the change journal (0054) sees.
- **History.** `history` gains a `record_id`, a random UUIDv4. The rowid stays for what never leaves the device: the full-text index joins on it, and pages and pins use it. A Mac history entry that moves into the core keeps its UUID.

## Rationale

- **Upper case for UUIDs.** RFC 9562 (section 4) writes lower case and reads either. The ids already on CloudKit are upper case, and a move pushes each record under its CloudKit id, so any other case gives every entity a second record.
- **The library keeps its ids.** Rewriting them would turn each unsent edit of a shipped Mac into a new item. A second form, confined to three team kinds, costs less.
- **Lower case for a new team record.** A shipped Mac publishes a connection under its lower-case UUID. A core device that wrote upper case would make a second item for the same connection whenever both publish before either pulls.
- **Derived ids byte for byte.** The rules are the Swift functions written out, so one favourite gets one id from Swift and from Rust, and the Mac's records keep their ids on the move.
- **The alias stays off TablePro Sync.** Only Macs before 0.77 read it, and they never reach the service.
- **UUIDv4 for history.** A UUIDv7 starts with its creation time in milliseconds (RFC 9562, section 5.7). Entries go up in batches, so the server does not learn when each query ran; a v7 id would tell it.
- **An optional connection.** The Mac's users already have queries and folders in every connection, and a required connection would drop them on the move.
- **Settling collisions, not refusing them.** The store keeps its unique places, so a save by name still names one query and a keyword still expands to one query, and no pull fails on a name. One rule on every device converges without a prompt.
- **No referential actions.** A cascade changes rows behind the change journal, and after a pulled deletion those rows would never go up as tombstones.

## Consequences

- 0017's integer ids are superseded, and its per-connection folders and keywords are amended. Its other rules stand.
- `tablepro-records` computes every id here, tested against fixtures the Mac's code produces. The collision fixtures include two records created in one second whose ids sort the other way, and a theme whose file name differs from its `id`.
- `history.db` gets a new migration, never an edit to one that shipped, with the copy [0012](0012-copies-before-a-format-upgrade.md) makes before it runs. Linux 0.1.0 betas shipped that database, so theirs upgrade through the migration (`linux/docs/storage.md`, Changing a format). Landing it before the first stable Linux release gives that release the final format. The Windows app has not released, so its files need no step.
- The FFI gives saved query and folder ids as UUID text. The Linux app, the Windows interop and its committed C# change with it.
- A Mac with two favorites of one name in one place gets one renamed when its store moves into the core, and the rename syncs.
- An older Mac's resolver contests only keywords held in one connection. The core also settles a keyword with no connection, which an older Mac applies as an ordinary edit.
- An older Mac compares its own records' dates below the millisecond. For two records created within one millisecond it can pick the other one, and both then lose the keyword.
- The settings ids `columnLayout.<table key>` and `theme.<theme id>` hold database, table and theme names, as readable to the operator as 0044 says.

## Alternatives considered

- **Matching ids without case on the server.** Categories, digests and key ids are case-sensitive, and the server reads no kind's id form.
- **Random ids for favourites.** Two devices marking one table would make two records, and the Mac's records could not be matched.
- **New, cleaner favourite ids for the service.** A move would map every id, and a Mac on iCloud and one on the service would disagree.
- **Integer ids mapped to UUIDs in the sync state.** A second id kept outside the store, which a restored or copied store loses.
- **Dropping the unique places to match the Mac.** A save by name would no longer name one query, and a keyword could expand to two.
- **Random envelope ids.** Two devices sealing one secret would leave two envelopes for it.
