-- Which copy of the database this is and how far its writes have gone (core ADR 0054, The engine).
-- The app stamps the one row when it opens a database that has none. A write to any table that
-- syncs raises the sequence through a trigger, whichever process or tool makes it, so a copy
-- brought back from a backup reads as older than the database sync last saw.
CREATE TABLE store_identity (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    generation TEXT NOT NULL,
    sequence   INTEGER NOT NULL DEFAULT 0
);

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
