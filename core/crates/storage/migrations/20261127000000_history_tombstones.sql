-- The history entries the person deleted, kept until sync has pushed each deletion (core ADR 0054, Dirty state is a
-- diff). A prune by the retention writes none, so it never deletes an entry on another device. The id keeps the
-- order the person deleted them in.
CREATE TABLE history_tombstones (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id TEXT NOT NULL UNIQUE
);
