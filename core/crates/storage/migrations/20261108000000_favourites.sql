-- Folders and keywords on saved queries, and the tables and databases a
-- user marks as favourites (core ADR 0017).

CREATE TABLE saved_query_folders (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    connection_id TEXT NOT NULL,
    name          TEXT NOT NULL,
    -- A deleted folder takes the folders inside it.
    parent_id     INTEGER REFERENCES saved_query_folders (id) ON DELETE CASCADE,
    sort_order    INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

-- No two siblings share a name in any case. A top-level folder has no
-- parent, which a unique index would treat as always different.
CREATE UNIQUE INDEX saved_query_folders_name_idx
    ON saved_query_folders (connection_id, COALESCE(parent_id, 0), name COLLATE NOCASE);

ALTER TABLE saved_queries ADD COLUMN keyword TEXT;
-- A deleted folder leaves its queries at the top.
ALTER TABLE saved_queries ADD COLUMN folder_id INTEGER REFERENCES saved_query_folders (id) ON DELETE SET NULL;
ALTER TABLE saved_queries ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;

CREATE UNIQUE INDEX saved_queries_keyword_idx
    ON saved_queries (connection_id, keyword COLLATE NOCASE) WHERE keyword IS NOT NULL;

-- A table is named by its database and schema where the engine has them,
-- and by the empty string where it does not, so the key is never NULL.
CREATE TABLE favourite_tables (
    connection_id TEXT NOT NULL,
    database      TEXT NOT NULL DEFAULT '',
    schema        TEXT NOT NULL DEFAULT '',
    name          TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    PRIMARY KEY (connection_id, database, schema, name)
);

CREATE TABLE favourite_databases (
    connection_id TEXT NOT NULL,
    database      TEXT NOT NULL,
    environment   TEXT NOT NULL DEFAULT 'unassigned'
        CHECK (environment IN ('development', 'testing', 'production', 'unassigned')),
    created_at    INTEGER NOT NULL,
    PRIMARY KEY (connection_id, database)
);
