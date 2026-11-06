//! The SQL dump round trip on DuckDB.

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, ConnectTarget, FileEndpoint, WorkspaceSettings};
use tablepro_test_support::conformance::{ConformanceEngine, ConformanceFailure, DumpEngine, test_liveness};

use crate::duckdb_engine::{DuckDbEngine, create_database};

#[async_trait]
impl DumpEngine for DuckDbEngine {
    /// A file of that name beside the engine's own, made by DuckDB with
    /// its default storage version, which takes triggers.
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let mut options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let ConnectTarget::File(endpoint) = &options.target else {
            return Err(ConformanceFailure::setup("the fixture opens a file"));
        };
        let path = endpoint.path().with_file_name(format!("{name}.duckdb"));
        for suffix in ["", ".wal"] {
            let mut leftover = path.clone().into_os_string();
            leftover.push(suffix);
            match std::fs::remove_file(&leftover) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(ConformanceFailure::setup(error));
                }
                _ => {}
            }
        }
        create_database(&path).map_err(ConformanceFailure::setup)?;
        options.target = ConnectTarget::File(FileEndpoint::open_existing(path).map_err(ConformanceFailure::setup)?);
        Ok(options)
    }

    /// DuckDB's triggers fire only after a row and may not write to
    /// their own table, so the trigger writes to another one: rows there
    /// beyond the one it made would show it firing during the load. Its
    /// table has no generated column, which a row trigger refuses. A
    /// table whose key points at itself takes its rows one at a time.
    fn dump_fixture(&self) -> Vec<String> {
        [
            "CREATE SCHEMA app",
            "CREATE TYPE app.mood AS ENUM ('sad', 'ok', 'happy')",
            "CREATE SEQUENCE app.parent_id_seq",
            "CREATE SEQUENCE app.child_id_seq",
            "CREATE TABLE app.parent (\
                 id INTEGER DEFAULT nextval('app.parent_id_seq') PRIMARY KEY, \
                 name VARCHAR NOT NULL UNIQUE, \
                 mood app.mood, \
                 score DOUBLE CHECK (score >= 0)\
             )",
            "CREATE TABLE app.child (\
                 id INTEGER DEFAULT nextval('app.child_id_seq') PRIMARY KEY, \
                 parent_id INTEGER NOT NULL, \
                 manager_id INTEGER, \
                 note VARCHAR, \
                 payload BLOB, \
                 note_length BIGINT GENERATED ALWAYS AS (length(note)) VIRTUAL, \
                 FOREIGN KEY (parent_id) REFERENCES app.parent (id), \
                 FOREIGN KEY (manager_id) REFERENCES app.child (id)\
             )",
            "CREATE TABLE app.audit (parent_id INTEGER NOT NULL, name VARCHAR NOT NULL)",
            "CREATE INDEX child_note_idx ON app.child (note)",
            "INSERT INTO app.parent (name, mood, score) VALUES \
             ('first', 'happy', 1.5), ('second', 'ok', 2), ('gone', NULL, 0)",
            "INSERT INTO app.child (parent_id, manager_id, note, payload) \
             VALUES (1, NULL, 'it''s; a \"quote\" \\ back', '\\x00\\xFF\\x27'::BLOB)",
            "INSERT INTO app.child (parent_id, manager_id, note, payload) \
             VALUES (1, 1, 'line one' || chr(10) || 'line two;', NULL)",
            "INSERT INTO app.child (parent_id, manager_id, note, payload) \
             VALUES (2, 2, 'Grüße, 東京 ✓', '\\xFF'::BLOB)",
            "INSERT INTO app.child (parent_id, manager_id, note, payload) VALUES (3, NULL, 'gone', NULL)",
            "DELETE FROM app.child WHERE id = 4",
            "DELETE FROM app.parent WHERE id = 3",
            "CREATE MACRO app.name_length(s) AS length(s)",
            "CREATE VIEW app.parent_names AS SELECT id, name FROM app.parent",
            "CREATE VIEW app.parent_name_lengths AS SELECT id, app.name_length(name) AS n FROM app.parent_names",
            "CREATE TRIGGER parent_audit AFTER INSERT ON app.parent FOR EACH ROW \
             INSERT INTO app.audit VALUES (NEW.id, NEW.name)",
            "INSERT INTO app.parent (name, mood, score) VALUES ('after the trigger', 'sad', 4)",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
}

mod suite {
    use super::DuckDbEngine;

    tablepro_test_support::dump_suite! {
        engine: DuckDbEngine,
        docker: false,
    }
}
