-- The tables `history.db` held for saved queries, their folders, favourites and table folders, as its migrations up to
-- 20261127000000 left them (core ADR 0017, 0052 and 0060 as amended). A store made from an older `history.db` gets its
-- rows under their own ids and rowids.

CREATE TABLE store_identity (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    generation TEXT NOT NULL,
    sequence   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE saved_query_folders (
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

CREATE TABLE saved_queries (
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

-- A table is named by its database and schema where the engine has them, and by the empty string where it does not,
-- so the key is never NULL.
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

-- No foreign key: a pull can bring an item before its folder, and an item whose folder is missing reads as unfiled.
CREATE TABLE table_folders (
    id            TEXT PRIMARY KEY NOT NULL,
    connection_id TEXT NOT NULL,
    database      TEXT NOT NULL DEFAULT '',
    schema        TEXT NOT NULL DEFAULT '',
    name          TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

CREATE INDEX table_folders_scope_idx ON table_folders (connection_id, database, schema);

-- A table sits in at most one folder.
CREATE TABLE table_folder_items (
    connection_id TEXT NOT NULL,
    database      TEXT NOT NULL DEFAULT '',
    schema        TEXT NOT NULL DEFAULT '',
    name          TEXT NOT NULL,
    folder_id     TEXT NOT NULL,
    PRIMARY KEY (connection_id, database, schema, name)
);

CREATE INDEX table_folder_items_folder_idx ON table_folder_items (folder_id);

-- A write to any of them raises the sequence, whichever process makes it (core ADR 0054, The engine).

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

CREATE TRIGGER favourite_tables_store_sequence_ai AFTER INSERT ON favourite_tables BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER favourite_tables_store_sequence_au AFTER UPDATE ON favourite_tables BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER favourite_tables_store_sequence_ad AFTER DELETE ON favourite_tables BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER favourite_databases_store_sequence_ai AFTER INSERT ON favourite_databases BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER favourite_databases_store_sequence_au AFTER UPDATE ON favourite_databases BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER favourite_databases_store_sequence_ad AFTER DELETE ON favourite_databases BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folders_store_sequence_ai AFTER INSERT ON table_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folders_store_sequence_au AFTER UPDATE ON table_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folders_store_sequence_ad AFTER DELETE ON table_folders BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folder_items_store_sequence_ai AFTER INSERT ON table_folder_items BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folder_items_store_sequence_au AFTER UPDATE ON table_folder_items BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;

CREATE TRIGGER table_folder_items_store_sequence_ad AFTER DELETE ON table_folder_items BEGIN
    UPDATE store_identity SET sequence = sequence + 1;
END;
