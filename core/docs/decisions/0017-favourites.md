# 0017: Favourites keep folders and keywords on saved queries, and the tables and databases a user marks

- **Status**: Accepted
- **Date**: 2026-11-08

## Context

The macOS sidebar has a Favorites scope next to Tables. It lists SQL favorites in folders, each with a name, a query and an optional keyword that expands in the editor, and the tables and databases the user marked, with each database filed under an environment (`SQLFavorite`, `SQLFavoriteFolder`, `FavoriteTablesStorage.FavoriteEntry`, `FavoriteDatabaseEntry`). The core keeps one half of this: `tablepro-storage` has saved queries, a name and a query per connection, in the query history's SQLite database. The Linux sidebar lists them, flat (linux PRs on the Favorites scope). Windows and the macOS app's move to the core ([0010](0010-macos-on-the-core.md)) need the rest, so it belongs in the core and not in one app.

## Decision

The folders, the keywords, the order and the marked tables and databases live in the history's database, added by one migration, `20261108000000_favourites.sql`, and reached through `QueryHistory::saved_queries`, `saved_query_folders` and `favourites`.

## Rationale

- **The same database.** Saved queries already live there, so a folder or a keyword is a column or a table beside them, in one transaction and one migration chain, and `delete_for_connection` removes all of a connection's favourites in one call.
- **Integer ids, not UUIDs.** A folder is a row of `saved_query_folders` with an `INTEGER` key, as a saved query has. macOS's UUID ids are not kept; a later importer maps them by name and place, as [0006](0006-connection-library.md) does for groups.
- **A folder is per connection**, with a parent id. Siblings never share a name in any case. Deleting a folder deletes the folders in it and leaves their queries at the top, as deleting a group does ([0006](0006-connection-library.md)). A folder never moves inside itself.
- **A keyword is one word**, at most 64 characters with no whitespace, unique among a connection's queries in any case, as macOS's unique index on keyword and connection. Folders nest without a depth limit, as on macOS.
- **Order is a number per place**, numbered from 0 again on each move, so a place always holds each position once.
- **A favourite table is keyed by connection, database, schema and name**, the empty string standing for none so the key is never `NULL`. A favourite database carries one of four environments, the four macOS buckets, in a column with a check.
- **Errors are `StorageError` variants with stable codes**: `storage.keyword_taken`, `keyword_invalid`, `folder_name_taken` and `folder_cycle`, with `not_found` and `empty_name` as before.

## Consequences

- A database an earlier build wrote is copied beside itself before the migration ([0012](0012-copies-before-a-format-upgrade.md)); a build before this one refuses it, as it refuses any newer one. The copies hold none of the new tables, since they are made from the older format, so deleting a folder or a favourite needs no trim of them.
- `SavedQuery` gains `keyword`, `folder_id` and `order`. `NewSavedQuery` is unchanged: a save keeps the keyword and the place of the query it replaces.
- Not here: the macOS team library, linked folders and per-file favourites, which stay outside the core, and the FFI surface, which a later change adds when Windows or macOS shows favourites.
- The Linux sidebar shows the folders, the keyword expansion and the marked tables and databases in later changes, each its own pull request.

## Alternatives considered

- **A JSON document, as the connection library.** Saved queries are in SQLite already, so folders in a file would split one list across two stores and two writers.
- **UUID ids to match macOS.** A second key beside the row id, and an id nothing here joins on.
- **A keyword unique across connections.** macOS scopes it to the connection, since a saved query is written for one database's schema.
