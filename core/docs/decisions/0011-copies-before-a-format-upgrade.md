# 0011: A file in an older format is copied beside itself before its first write in the newer one

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

Every file `tablepro-storage` owns carries its format version: a JSON document its `version` field (`VersionedDocument`), the query history database its sqlx migrations. A newer build reads an older file through upgrade steps in memory, and a build refuses a file whose version it does not know. The next save then wrote the upgraded file straight over the old one: opening a saved connection stamps its last-opened time, so a plain open after an update rewrote `connections.json`, and `QueryHistory::open` migrated `history.db` in place, saved queries included. An atomic write protects a write in progress, not the way back: after an update, the older build refused everything the newer one had written once.

## Decision

Before the first write that replaces a file holding an older format, the storage crate keeps a private copy of it beside the file, named `<file>.v<version>-<unix seconds>`, keeps the newest three per file, and refuses the write when the copy cannot be made.

## Rationale

- **One write path decides it.** `document::write_document_blocking` reads the version of the file on disk and copies an older one before writing, so every store that writes a versioned document gets the copy without remembering what it read. The Linux app's workspace writer, which injects its own write for tests, calls `upgrade_copies::keep_before_write_blocking` the same way.
- **A database is copied through SQLite, not as a file.** `history.db` runs in WAL mode, and a copy of the main file alone misses what the WAL still holds ([How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html), 1.2 and 1.4). `VACUUM INTO` through the open connection writes a consistent snapshot ([VACUUM](https://www.sqlite.org/lang_vacuum.html#vacuuminto)) before any migration runs. It goes to a `.partial` file created 0600, is synced and renamed into place, so a copy cut short never carries a finished name.
- **Beside the file, like the copies a Reset moves aside.** `connections.json.v1-…` sits next to `connections.json.corrupt-…`, a restore is a rename in one folder, and a session's purge removes its copies with its file.
- **Three per file, as Chromium keeps three user-data snapshots** taken at each major update for a rollback ([Keep data during version rollback](https://support.google.com/chrome/a/answer/9917429)). A copy whose bytes match the newest one is not made again.
- **No copy, no write.** A failed copy fails the write, the file stays as it was, and the app words the error by the copy's path like any other failed write. Upgrading without the way back is what this decision removes.
- **A copy never holds what the user deleted.** After any deletion from the history or the saved queries, and after each retention prune, a history copy keeps only the rows the database still has, deleted in one transaction with `secure_delete` and its full-text indexes optimized. A deleted connection leaves each copy of the connection list, and its column layout and filter copies are deleted. Mirroring each delete statement instead missed pins changed after the copy and left words behind after a crash between steps.

## Consequences

- An older build reads the copy of its own format once the user puts it back (`linux/docs/troubleshooting.md`, After a downgrade). Nothing restores a copy on its own.
- A copy holds what the file held at the upgrade, including connections deleted since. It is as private as the file: 0600 in the app's 0700 folders.
- A history copy is as large as the database after `VACUUM`, and three of them can sit beside it.
- Reading never makes a copy, so a newer build that only looks and is then removed leaves nothing behind.
- The Windows and macOS apps get the same copies through `ConnectionStore`, under their own storage folders.
- Every stored format starts again at version 1 for the first release, so no copy is made until a later release raises one. The hook is tested with a synthetic version bump of a document and of a migration list.

## Alternatives considered

- **Copies in one backup folder.** Easier to list, but every store would need the folder passed in, and a store that forgot would write without a copy. Beside the file needs no wiring.
- **Copy at read time.** Leaves a copy behind for every build that only reads, and the copy would not be the one the write replaced if the file changed in between.
- **Warn and upgrade when the copy fails.** Keeps writes working on a broken folder, but loses the way back silently, which is the failure this decision is about.
- **The SQLite backup API** (`sqlite3_backup`). Uses less CPU and runs in steps, but sqlx does not expose it, and `VACUUM INTO` is one statement that also leaves no deleted content in the copy.
