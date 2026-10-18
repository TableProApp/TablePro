CREATE TABLE IF NOT EXISTS saved_queries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    query           TEXT NOT NULL,
    connection_id   TEXT NOT NULL,
    connection_name TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS saved_queries_name_idx
    ON saved_queries (connection_id, name);
