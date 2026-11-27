-- Record ids for saved queries, their folders and the history (core ADR 0052). Each integer key stays
-- as the rowid that the full-text index, pages, pins and the upgrade copies match on. A folder is
-- named by its record id, with no foreign key, so a pull can bring a query before its folder and a
-- delete changes no row behind the store's code. Saved queries and folders keep whole milliseconds.
-- SQLite changes a column's constraints only by rebuilding its table.

CREATE TEMP TABLE drawn_ids (
    source TEXT NOT NULL,
    id     INTEGER NOT NULL,
    hex    TEXT NOT NULL,
    PRIMARY KEY (source, id)
);

INSERT INTO temp.drawn_ids (source, id, hex)
    SELECT 'folder', id, lower(hex(randomblob(16))) FROM saved_query_folders;
INSERT INTO temp.drawn_ids (source, id, hex)
    SELECT 'query', id, lower(hex(randomblob(16))) FROM saved_queries;
INSERT INTO temp.drawn_ids (source, id, hex)
    SELECT 'history', id, lower(hex(randomblob(16))) FROM history;

-- Random bits with the version 4 and variant 10 bits set (RFC 9562, section 5.4).
CREATE TEMP TABLE record_ids AS
    SELECT source, id,
        substr(hex, 1, 8) || '-' || substr(hex, 9, 4) || '-4' || substr(hex, 14, 3) || '-'
        || substr('89ab', (instr('0123456789abcdef', substr(hex, 17, 1)) - 1) % 4 + 1, 1)
        || substr(hex, 18, 3) || '-' || substr(hex, 21, 12) AS record_id
    FROM temp.drawn_ids;

CREATE TABLE saved_query_folders_new (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id        TEXT NOT NULL UNIQUE,
    -- None puts the folder in every connection.
    connection_id    TEXT,
    name             TEXT NOT NULL,
    parent_record_id TEXT,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
);

INSERT INTO saved_query_folders_new
    (id, record_id, connection_id, name, parent_record_id, sort_order, created_at, updated_at)
SELECT folder.id, own.record_id, folder.connection_id, folder.name, parent.record_id, folder.sort_order,
    folder.created_at * 1000, folder.updated_at * 1000
FROM saved_query_folders folder
JOIN temp.record_ids own ON own.source = 'folder' AND own.id = folder.id
LEFT JOIN temp.record_ids parent ON parent.source = 'folder' AND parent.id = folder.parent_id;

CREATE TABLE saved_queries_new (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id        TEXT NOT NULL UNIQUE,
    name             TEXT NOT NULL,
    query            TEXT NOT NULL,
    -- None puts the query in every connection.
    connection_id    TEXT,
    connection_name  TEXT NOT NULL,
    keyword          TEXT,
    folder_record_id TEXT,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
);

INSERT INTO saved_queries_new
    (id, record_id, name, query, connection_id, connection_name, keyword, folder_record_id, sort_order,
     created_at, updated_at)
SELECT query.id, own.record_id, query.name, query.query, query.connection_id, query.connection_name,
    query.keyword, folder.record_id, query.sort_order, query.created_at * 1000, query.updated_at * 1000
FROM saved_queries query
JOIN temp.record_ids own ON own.source = 'query' AND own.id = query.id
LEFT JOIN temp.record_ids folder ON folder.source = 'folder' AND folder.id = query.folder_id;

CREATE TABLE history_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id       TEXT NOT NULL UNIQUE,
    query           TEXT NOT NULL,
    -- The query lowercased by Unicode rules, which SQLite's lower() does
    -- not follow, so the app writes it.
    query_folded    TEXT NOT NULL,
    driver_id       TEXT NOT NULL,
    connection_id   TEXT NOT NULL,
    connection_name TEXT NOT NULL,
    executed_at     INTEGER NOT NULL,
    duration_ms     INTEGER,
    rows_affected   INTEGER,
    success         INTEGER NOT NULL,
    cancelled       INTEGER NOT NULL DEFAULT 0,
    pinned          INTEGER NOT NULL DEFAULT 0,
    error           TEXT
);

INSERT INTO history_new
    (id, record_id, query, query_folded, driver_id, connection_id, connection_name, executed_at,
     duration_ms, rows_affected, success, cancelled, pinned, error)
SELECT entry.id, own.record_id, entry.query, entry.query_folded, entry.driver_id, entry.connection_id,
    entry.connection_name, entry.executed_at, entry.duration_ms, entry.rows_affected, entry.success,
    entry.cancelled, entry.pinned, entry.error
FROM history entry
JOIN temp.record_ids own ON own.source = 'history' AND own.id = entry.id;

-- AUTOINCREMENT never gives a deleted row's id again, and dropping a table drops its sequence.
CREATE TEMP TABLE kept_sequences AS
    SELECT name, seq FROM sqlite_sequence WHERE name IN ('saved_query_folders', 'saved_queries', 'history');

-- Rewriting every row for the rebuild edits no record, so it raises no store sequence.
DROP TRIGGER history_store_sequence_ai;
DROP TRIGGER history_store_sequence_au;
DROP TRIGGER history_store_sequence_ad;
DROP TRIGGER saved_queries_store_sequence_ai;
DROP TRIGGER saved_queries_store_sequence_au;
DROP TRIGGER saved_queries_store_sequence_ad;
DROP TRIGGER saved_query_folders_store_sequence_ai;
DROP TRIGGER saved_query_folders_store_sequence_au;
DROP TRIGGER saved_query_folders_store_sequence_ad;

-- Migrations run with foreign keys on, and dropping a table deletes its rows first: the queries go
-- before the folders they reference, and the folders let go of their parents so no cascade runs.
DROP TABLE saved_queries;
DROP INDEX saved_query_folders_name_idx;
UPDATE saved_query_folders SET parent_id = NULL WHERE parent_id IS NOT NULL;
DROP TABLE saved_query_folders;
DROP TABLE history;

ALTER TABLE saved_query_folders_new RENAME TO saved_query_folders;
ALTER TABLE saved_queries_new RENAME TO saved_queries;
ALTER TABLE history_new RENAME TO history;

UPDATE sqlite_sequence
    SET seq = (SELECT kept.seq FROM temp.kept_sequences kept WHERE kept.name = sqlite_sequence.name)
    WHERE seq < (SELECT kept.seq FROM temp.kept_sequences kept WHERE kept.name = sqlite_sequence.name);
INSERT INTO sqlite_sequence (name, seq)
    SELECT kept.name, kept.seq FROM temp.kept_sequences kept
    WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence held WHERE held.name = kept.name);

DROP TABLE temp.kept_sequences;
DROP TABLE temp.record_ids;
DROP TABLE temp.drawn_ids;

-- A name is unique among the queries of one connection, or of none.
CREATE UNIQUE INDEX saved_queries_name_idx ON saved_queries (COALESCE(connection_id, ''), name);
-- The store's code also keeps a keyword of no connection unique among every query.
CREATE UNIQUE INDEX saved_queries_keyword_idx
    ON saved_queries (COALESCE(connection_id, ''), keyword COLLATE NOCASE) WHERE keyword IS NOT NULL;
CREATE INDEX saved_queries_folder_order_idx ON saved_queries (connection_id, folder_record_id, sort_order, id);

-- No two folders of one connection, or of none, share a name in any case under one parent.
CREATE UNIQUE INDEX saved_query_folders_name_idx
    ON saved_query_folders (COALESCE(connection_id, ''), COALESCE(parent_record_id, ''), name COLLATE NOCASE);
CREATE INDEX saved_query_folders_parent_idx ON saved_query_folders (parent_record_id);
CREATE INDEX saved_query_folders_order_idx ON saved_query_folders (connection_id, parent_record_id, sort_order, id);

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

CREATE INDEX history_executed_at_idx ON history (executed_at DESC);
CREATE INDEX history_connection_idx ON history (connection_id, executed_at DESC);
CREATE INDEX history_page_idx ON history (pinned DESC, executed_at DESC, id DESC);

-- The store identity's triggers (20261125000000_store_identity.sql) went with the old tables.
CREATE TRIGGER history_store_sequence_ai AFTER INSERT ON history BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER history_store_sequence_au AFTER UPDATE ON history BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER history_store_sequence_ad AFTER DELETE ON history BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_queries_store_sequence_ai AFTER INSERT ON saved_queries BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_queries_store_sequence_au AFTER UPDATE ON saved_queries BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_queries_store_sequence_ad AFTER DELETE ON saved_queries BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_query_folders_store_sequence_ai AFTER INSERT ON saved_query_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_query_folders_store_sequence_au AFTER UPDATE ON saved_query_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER saved_query_folders_store_sequence_ad AFTER DELETE ON saved_query_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;
