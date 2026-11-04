CREATE TABLE IF NOT EXISTS history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    query           TEXT NOT NULL,
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

CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
    query,
    content='history',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
    INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
END;

CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
    INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
END;

CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE OF query ON history BEGIN
    INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.id, old.query);
    INSERT INTO history_fts(rowid, query) VALUES (new.id, new.query);
END;

CREATE INDEX IF NOT EXISTS history_executed_at_idx ON history (executed_at DESC);
CREATE INDEX IF NOT EXISTS history_pinned_idx ON history (pinned DESC, executed_at DESC);
CREATE INDEX IF NOT EXISTS history_connection_idx ON history (connection_id, executed_at DESC);
