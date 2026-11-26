-- Folders a person files a connection's tables in, per database and schema, and the table each
-- file names (core ADR 0052, Ids per kind). No foreign key: a pull can bring an item before its
-- folder, and an item whose folder is missing reads as unfiled. Times are whole milliseconds.
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
