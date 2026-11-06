CREATE TABLE history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
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

CREATE VIRTUAL TABLE history_search USING fts5(
    query_folded,
    content='history',
    content_rowid='id',
    tokenize='trigram case_sensitive 1'
);

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

CREATE TABLE saved_queries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    query           TEXT NOT NULL,
    connection_id   TEXT NOT NULL,
    connection_name TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE UNIQUE INDEX saved_queries_name_idx ON saved_queries (connection_id, name);
