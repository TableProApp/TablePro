# 0060: The change journal names the records each write changed, and a store is one file

- **Status**: Accepted; amends 0054; per-kind refills amended by 0066; the `history.db` example amended by 0069
- **Date**: 2026-11-26

## Context

The store models lane (#4560) built [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md)'s change journal and store identity, and found three gaps that block the downgrade mirror and the engine lanes:

- **The journal.** 0054, The engine, says the journal "names the kind". Its downgrade mirror then writes, on every journal signal, "the dirty and tombstone keys of the records that write changed". With kinds alone, the mirror would have to diff a whole store against its bases on every write. 0054 gives no reason for kinds alone: its one constraint, that the diff decides what goes up and a missed call loses nothing, holds with record ids too.
- **What one store is.** 0054 says each store keeps a generation id and a write sequence, but not what a store is. That decides what a restore refills.
- **The restore path.** 0054 names two Swift stores as the ones that write a new generation when they restore, while the core keeps the generation.

0054 is Accepted, so these go in a new ADR, and 0054 changes only its Status line.

## Decision

- **The journal** names, for each committed write, the kind with the ids of the records the commit wrote and the ids it deleted, after the commit lands. The diff still decides what a pass sends, so a missed call still only delays a push. The downgrade mirror writes those ids as the previous stable's dirty and tombstone keys. Neither the mirror nor the engine diffs a whole store against its bases on a signal.
- **A store is one file** the core keeps, such as `connections.json` or `history.db`, with one generation id and one write sequence. A new generation or a lower sequence puts every kind that file holds into refill together, so a restored `history.db` refills its history, saved queries and folders, and favourites at once.
- **The restore path.** A host that puts a store's file back calls that store's `start_new_generation` in the core, which writes the new generation. `IntegrityStampedFileStore` and the iOS `LibraryFile` call it once their stores are the core's.

## Consequences

- The journal API carries record ids beside kinds; the signal that names only kinds goes.
- The downgrade mirror reads its dirty and tombstone keys from the journal.
- A restore of one file refills every kind in it, not only the one the person changed.
