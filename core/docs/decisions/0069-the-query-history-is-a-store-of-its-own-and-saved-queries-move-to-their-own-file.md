# 0069: The query history is a store of its own, and saved queries move to `saved_queries.db`

- **Status**: Accepted; amends 0017, 0030 and 0060
- **Date**: 2026-11-27

## Context

[0060](0060-the-change-journal-names-the-records-each-write-changed-and-a-store-is-one-file.md) makes a store one file, with `history.db` as its example: the query history, the saved queries and their folders, and the favourites, which [0017](0017-favourites.md) put beside the saved queries, and the table folders after them. On iOS a file has one data protection class. The history is query text the person ran, which should stay unreadable while the device is locked. Saved queries, favourites and table folders sync in the background, which needs a class that stays readable after the first unlock. One file cannot have both. The maintainer decided on 2026-11-26 to split the file and keep 0060's rule that a store is one file. 0017, 0030 and 0060 are Accepted, so the split goes here, and they change only their Status lines.

## Decision

- **Two stores.** `history/history.db` in the state folder holds the query history alone: its entries, their full-text index and the tombstones of the person's deletions. `saved_queries.db`, in the state folder, holds the saved queries and their folders, the favourite tables and databases, and the table folders. Each keeps its own generation, write sequence and change journal (0060), so a restored history refills the history alone, and a restored `saved_queries.db` refills its six kinds together.
- **Store names.** The engines name the `history_entry` kind's store `history.db`, and the `saved_query`, `saved_query_folder`, `favourite_table`, `favourite_database`, `table_folder` and `table_folder_item` kinds' store `saved_queries.db`. `saved_queries.db` starts a generation of its own; the history's generation and sequence do not move. A state file that saw `history.db` and not `saved_queries.db` keeps those six kinds' bases and moves any refill they owed under `history.db` to `saved_queries.db`, so the split refills nothing.
- **The move out.** A `history.db` an earlier build wrote keeps those rows until a migration drops their tables, and they move once, whichever store opens first. Under the history's write lock (`BEGIN IMMEDIATE`) they are copied into `.saved_queries.db.partial` beside `saved_queries.db`, which is synced. The saved queries, their folders and the table folders keep their ids, and the saved queries and their folders keep their AUTOINCREMENT counters; favourites and table folder items have derived ids (0052). The drop then commits in the same transaction, and only then is the build renamed to `saved_queries.db`. A crash before the drop leaves `history.db` as it was, and the build is made again; a crash after it leaves a whole build, which the next open of either store renames. `saved_queries.db` never exists half made, so sync never reads a missing row as a deletion.
- **A `history.db` put back.** A `saved_queries.db` already there while the history still holds those rows is what putting back an older `history.db` leaves, such as the copy an upgrade kept ([0012](0012-copies-before-a-format-upgrade.md)). That restores the history alone: `saved_queries.db` stays as it is, the drop still applies, and the copy the upgrade keeps of the file put back holds its saved tables.
- **Upgrade copies.** The copies of `history.db` kept before the move hold both stores' tables. Each store's deletions trim its own tables out of those copies as out of its own file's copies, so 0012's rule that a copy never holds what the person deleted holds across the split.
- **A folder for the history.** In the same open, `history.db` moves into `history/` with its upgrade copies. The core makes the folder only when it is missing, so a host that makes it first with a protection class gives that class to every file SQLite and the copies make in it. On Unix the core still sets the folder to 0700.
- **Moving the history under one lock.** Releases before the folder, the Linux betas up to 0.1.0-beta.5 among them, open `history.db` where it was, and one of their processes can run beside this one. The old file is opened with exclusive locking and a truncating rollback journal, with `secure_delete` on. Setting that journal needs the only connection to it and writes its WAL into it, and the connection keeps the lock until it closes. Under that lock, in this order:
  1. A partial copy an earlier attempt left in `history/` is removed.
  2. The file is copied into `history/` with `VACUUM INTO` and synced.
  3. One transaction drops every table the old file holds, inserts a migration row whose version no build has (`i64::MAX`), and creates `compaction_owed`.
  4. The upgrade copies move into the folder, each with its journals, the journals first.
  5. The copy is renamed to `history/history.db`, and both folders are synced.

  A write lands before the copy or not at all. When another process holds the old file, the open of either store fails with an I/O error, and a later open tries again. A release before the folder reads the migration row as a file a newer release wrote and refuses to open it.
- **What is owed is recorded and checked on every open.** The transaction that frees pages, the drop in `history.db` and the mark in the old file, also makes a `compaction_owed` table in that file. While the table is there, an open runs `VACUUM`, then a truncating WAL checkpoint, and drops the table once both finish. A crash, a failed `VACUUM` or a reader that blocks the checkpoint leaves it for a later open and does not fail the open. Every open of either store tidies the old file: once it is marked, any journal beside it is removed under its write lock, then it is compacted.
- **The gap left.** A crash between the copy and the mark, followed by a return to an older release before this one opens again, leaves the copy in `history/` with the history's text until this release's next open. Without the lock, that copy may be another process's move in progress, so it cannot be removed sooner.
- **Reading the history to open saved queries.** Opening `saved_queries.db` reads the history's rows only while `saved_queries.db` is not there or a build waits beside it. It still opens the old `history.db` in the state folder to move it into `history/` or to tidy it. Once both moves are done, saved queries open while `history/history.db` cannot be read.
- **Protection is the host's.** The core sets no data protection class. `Core::store_files` names the history's folder and both files from the Core's paths, creating nothing, so a host can set its platform's class on each before either opens.
- **The FFI.** `Core::saved_query_database` opens `saved_queries.db` once per Core, and its `SavedQueryDatabaseStore` gives the saved queries, favourites and table folders that `QueryHistoryStore` gave before ([0030](0030-storage-import-and-library-through-the-ffi.md)).

## Rationale

- **Two files, not one file with two classes.** iOS sets a class per file, so the history and the stores sync reads in the background cannot share one.
- **A put-back history restores the history alone.** A digest of what `saved_queries.db` took cannot tell an older release's edit from this release's own trimming or a migration's new ids, so nothing replaces the saved queries' store on that evidence.

## Consequences

- An older release refuses the `history.db` left in the state folder, and one past the drop, as it refuses any newer schema. Its way back is the copy 0012 keeps, now in `history/`. What the older release then changes in saved queries reaches the newer one only if `saved_queries.db` was moved aside with `history.db`; otherwise it stays in the copy kept at the next upgrade, under 0012's trimming.
- On Unix, `history.db`, `saved_queries.db` and their copies are 0600 in the app's 0700 folders, as before. Windows keeps its ACLs.
- A store that opens either file can fail while another process holds the old `history.db`, until that process lets go.
