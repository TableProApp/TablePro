# 0002: The connection library holds a group tree, manual order and favourites

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

The saved-connection list in `tablepro-storage` filed each connection under a group name, and had no favourites and no order of its own. The Windows Connections page shows Favorites, Recent and nested groups with drag and drop and manual order, as the macOS library does. The macOS library keeps groups in a tree (`ConnectionGroup`: id, name, color, SF Symbol icon, parent, sort order, at most 3 levels deep), and each connection's `groupId`, `sortOrder` and `isFavorite`, with the favourites' order and the last-connected times in preferences.

## Decision

`connections.json` version 3 holds the library: a list of groups that form a tree, each connection's group id and place in it, and an ordered list of favourites, changed only through `ConnectionStore` operations that keep the tree whole.

## Rationale

- **Groups are entities with ids.** A rename, a move or a colour reaches every connection in the group, two groups can share a name in different places, and a group can be empty, as on macOS.
- **The tree is a parent id per group**, with the macOS rules: at most 3 levels (`ConnectionGroup::MAX_DEPTH`), no two siblings named alike in any case, no cycle. Reads repair what a hand-edited file breaks: a missing parent or a cycle roots the group, a repeated id keeps its first entry, a connection in a group the list lacks moves to the top.
- **Order is an explicit `order` per group among its siblings and per connection within its group**, numbered from 0 again on every write, so a file always holds one place per item. A new entry, or one moved to another group, goes last there.
- **Favourites are one ordered list of connection ids.** Membership and order cannot disagree, which macOS has to reconcile between `isFavorite` and `favoritesOrder`. Deleting a connection drops it.
- **Recent stays derived from `last_opened_at`.** `ConnectionList::recent` lists opened connections newest first and leaves favourites out, as the macOS outline does.
- **Validation errors are `StorageError` variants with stable codes**: `storage.group_not_found`, `group_exists`, `group_name_taken`, `group_cycle`, `group_too_deep` and `connection_not_found`.

## Consequences

- Version 2 files read through an upgrade step. Each group name, cleaned as before, becomes a top-level group; identical names share one group, and names that differ in case stay two. The group id is derived from the name (`ConnectionGroup::legacy`), so every read and every import of an old file gives the same group. Groups and each group's connections are numbered by name, the order the Linux app listed them in. The file is rewritten as version 3 at the next save; a build before this one refuses a version 3 file instead of dropping its groups.
- Deleting a group deletes its subtree, and its connections move to the top level after the ones there, as macOS does.
- An import matches groups by id, then by the same name in the same place, and adds the rest; it adds favourites and never removes one, since an older file lists none.
- The Linux app shows a group by its path, such as `Work / Staging`, wherever it lists groups, and makes new groups at the top. The MCP server's `list_connections` names the same path.
- Sort mode, the Recent switch and the recent count are per-device view preferences that each app keeps in its own settings store.

## macOS mapping

| macOS | Core |
|---|---|
| `ConnectionGroup.id`, `name`, `parentId`, `sortOrder` | `ConnectionGroup.id`, `name`, `parent_id`, `order` |
| `ConnectionGroup.color` | `color`: `None` for None, `Slate` for Gray, and Red, Orange, Yellow, Green, Blue, Purple and Pink by name |
| `ConnectionGroup.iconName` | `icon`: `GroupIcon::Symbol` with the SF Symbol name; `GroupIcon::Named` for the icons every app draws |
| `DatabaseConnection.groupId`, `sortOrder` | `SavedConnection.group_id`, `order` |
| `isFavorite` and `favoritesOrder` | `favorites`: the order list kept to favourites, then any other favourite by name |
| `RecentConnectionsLedger` | each connection's `last_opened_at`, the newest time the ledger holds |
| Bundle format 1 (`groupName`) | a top-level group per name, as the version 2 upgrade does; the core does not read bundles yet |
| Bundle format 2 (`groups` with `ref` and `parentRef`, `groupRef`) | the same tree; a bundle carries no order or favourites |

What the core cannot hold exactly: a group name over 64 characters or with control characters is cut and cleaned as a Linux one is, and the core's `Teal` has no macOS colour. Linked folders and the team library are not stored in the library, so they stay outside it.

## Alternatives considered

- **Group names on connections, as before.** No empty group, no colour or icon, and renaming a parent rewrites every descendant's connections.
- **A favourite flag on each connection beside an order list.** Two sources that drift, as `favoritesOrder` does on macOS.
- **Order from the position in the file's array.** An edit rewrites the entry at the end of the array, which would move it.
- **Random ids for upgraded groups.** Each read before the first save would give the groups new ids, and importing an old export twice would add the group twice.
