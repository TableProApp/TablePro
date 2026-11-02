-- Search by substring: a trigram index over the query folded to lower
-- case replaces the word index. The fold follows Unicode rules, which
-- SQLite's lower() does not, so the app writes it. Rows from before this
-- migration start with NULL and QueryHistory::open folds them.
ALTER TABLE history ADD COLUMN query_folded TEXT;

DROP TRIGGER IF EXISTS history_ai;
DROP TRIGGER IF EXISTS history_ad;
DROP TRIGGER IF EXISTS history_au;
DROP TABLE IF EXISTS history_fts;

CREATE VIRTUAL TABLE history_search USING fts5(
    query_folded,
    content='history',
    content_rowid='id',
    tokenize='trigram case_sensitive 1'
);

-- Index the NULLs now, so the update trigger's delete of each one
-- removes a row the index holds.
INSERT INTO history_search(history_search) VALUES('rebuild');

CREATE TRIGGER history_search_ai AFTER INSERT ON history BEGIN
    INSERT INTO history_search(rowid, query_folded) VALUES (new.id, new.query_folded);
END;

CREATE TRIGGER history_search_ad AFTER DELETE ON history BEGIN
    INSERT INTO history_search(history_search, rowid, query_folded) VALUES('delete', old.id, old.query_folded);
END;

CREATE TRIGGER history_search_au AFTER UPDATE OF query_folded ON history BEGIN
    INSERT INTO history_search(history_search, rowid, query_folded) VALUES('delete', old.id, old.query_folded);
    INSERT INTO history_search(rowid, query_folded) VALUES (new.id, new.query_folded);
END;

DROP INDEX IF EXISTS history_pinned_idx;
CREATE INDEX history_page_idx ON history (pinned DESC, executed_at DESC, id DESC);
-- Empty once the rows are folded, so finding none left costs nothing.
CREATE INDEX history_unfolded_idx ON history (id) WHERE query_folded IS NULL;
