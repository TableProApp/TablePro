# 0070: A library write lists the secrets it takes out, and deletes them once it lands

- **Status**: Accepted
- **Date**: 2026-11-27

## Context

`ConnectionLibrary::replace_library` writes a whole library into `connections.json` for an app whose store moves into the core: the iOS app, and the Mac's SSH and credential profiles (#4633). A write that takes out a connection, an SSH profile or a credential profile must take that record's secrets with it. The secrets live in the host's store, the Keychain on the Apple apps, which the core reaches through `HostSecrets`. A file write and a Keychain delete cannot commit together.

The first plan deleted a profile's secrets before the write. A write that is then refused, because the file changed since the host read it (`LibraryChanged`), or that fails, has deleted the secrets of records that stay. Deleting after the write with nothing recorded leaves the secrets behind for good when the process stops between the two.

## Decision

The write records what it owes in the file it writes, and pays it after it lands.

- **In the same file write as the change,** `secrets_to_delete` in `connections.json` lists a `SecretOwner`, a kind and an id, for each SSH or credential profile the write takes out and each connection its `removing` names. A readable connection the write leaves out keeps its secrets: the host keeps those itself.
- **After the write lands,** under the same write lock, the core asks the host to delete each listed owner whose id the file no longer holds for that kind, then writes the list without the ones that went. An owner whose id the file holds again leaves the list and keeps its secrets.
- **What stays listed.** An owner the host could not delete stays listed and goes on the next `replace_library`, after that write's digest check. A write that could not take the lock file deletes nothing and leaves the list. `HostSecrets` answers `Deleted`, or `NotOwned` for secrets another app keeps, as iOS answers for the Mac's. Both clear the entry, and only an error keeps it.
- **A rebuild drops the list.** `rebuild_library` replaces a file its host cannot vouch for, so no secret goes by that file's ids.
- **An older build** that does not know the list leaves it out of its next write.

`linux/docs/storage.md`, Connection metadata, holds the store's side.

## Consequences

- No secret goes for a record the file still holds, and a refused or failed write deletes none.
- A crash between the file write and the deletes leaves the list, and the next `replace_library` finishes it.
- Secrets can outlive their record: until the next `replace_library` after a failed delete, after a rebuild, and after an older build's write.
- `HostSecrets::delete_connection` and `delete_profile` run while the core holds the library's lock, so a host must not call the library from them.

## Alternatives considered

- **Delete the secrets first.** A write refused as `LibraryChanged`, or one that fails, would lose the secrets of records that stay.
- **Delete after the write, with no record.** A stop between the two orphans the secrets with nothing left to find them.
- **A list in a file of its own.** It would need its own commit beside `connections.json`, with the same crash window between the two files.
