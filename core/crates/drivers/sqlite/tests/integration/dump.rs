//! The SQL dump round trip on SQLite.

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, ConnectTarget, FileEndpoint, WorkspaceSettings};
use tablepro_test_support::conformance::{
    ConformanceEngine, ConformanceFailure, DumpEngine, NativeDump, test_liveness,
};

use crate::sqlite_engine::{SqliteEngine, create_database};

#[async_trait]
impl DumpEngine for SqliteEngine {
    /// A file of that name beside the engine's own.
    async fn empty_database(&self, name: &str) -> Result<ConnectOptions, ConformanceFailure> {
        let mut options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let ConnectTarget::File(endpoint) = &options.target else {
            return Err(ConformanceFailure::setup("the fixture opens a file"));
        };
        let path = endpoint.path().with_file_name(format!("{name}.sqlite3"));
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let mut leftover = path.clone().into_os_string();
            leftover.push(suffix);
            match std::fs::remove_file(&leftover) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(ConformanceFailure::setup(error));
                }
                _ => {}
            }
        }
        create_database(&path).await.map_err(ConformanceFailure::setup)?;
        options.target = ConnectTarget::File(FileEndpoint::open_existing(path).map_err(ConformanceFailure::setup)?);
        Ok(options)
    }

    /// SQLite has no sequences or routines. Its counters are
    /// `sqlite_sequence`, and the trigger counts its own firings in the
    /// row it fires on.
    fn dump_fixture(&self) -> Vec<String> {
        [
            "CREATE TABLE parent (\
                 id INTEGER PRIMARY KEY AUTOINCREMENT, \
                 name TEXT NOT NULL UNIQUE, \
                 score REAL CHECK (score >= 0)\
             )",
            "CREATE TABLE child (\
                 id INTEGER PRIMARY KEY AUTOINCREMENT, \
                 parent_id INTEGER NOT NULL REFERENCES parent (id), \
                 manager_id INTEGER REFERENCES child (id), \
                 note TEXT, \
                 payload BLOB, \
                 note_length INTEGER GENERATED ALWAYS AS (length(note)) VIRTUAL, \
                 touched INTEGER NOT NULL DEFAULT 0\
             )",
            "CREATE TABLE plain (k TEXT, v REAL)",
            "CREATE INDEX child_parent_idx ON child (parent_id)",
            "INSERT INTO parent (name, score) VALUES ('first', 1.5), ('second', 2), ('gone', 0)",
            "INSERT INTO child (parent_id, manager_id, note, payload) VALUES \
             (1, NULL, 'it''s; a \"quote\" \\ back', X'00FF27'), \
             (1, 1, 'line one' || char(10) || 'line two;', NULL), \
             (2, 2, 'Grüße, 東京 ✓', X'FF'), \
             (3, NULL, 'gone', NULL)",
            "DELETE FROM child WHERE id = 4",
            "DELETE FROM parent WHERE id = 3",
            "INSERT INTO plain (k, v) VALUES ('x', 1.5), ('y', NULL)",
            "CREATE VIEW parent_names AS SELECT id, name FROM parent",
            "CREATE VIEW parent_name_lengths AS SELECT id, length(name) AS n FROM parent_names",
            "CREATE TRIGGER child_touch AFTER INSERT ON child BEGIN \
                 UPDATE child SET touched = touched + 1 WHERE id = NEW.id; \
             END",
            "INSERT INTO child (parent_id, manager_id, note) VALUES (2, 3, 'after the trigger')",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }

    /// `sqlite3 .dump` from 3.46.1, the shell Ubuntu 26.04 ships: its
    /// own `PRAGMA foreign_keys=OFF; BEGIN TRANSACTION; ... COMMIT;`, a
    /// child row that points at a later one, and `sqlite_sequence`.
    fn native_dump(&self) -> Option<NativeDump> {
        let checks = [
            ("SELECT count(*) FROM child", "4"),
            ("SELECT seq FROM sqlite_sequence WHERE name = 'child'", "5"),
            ("SELECT note FROM child WHERE id = 2", "line1\nline2;"),
            ("SELECT hex(payload) FROM child WHERE id = 1", "00FF27"),
            ("SELECT count(*) FROM v2", "3"),
        ];
        Some(NativeDump {
            file: include_str!("fixtures/sqlite3-3.46-dump.sql"),
            checks: checks
                .into_iter()
                .map(|(sql, value)| (sql.to_owned(), value.to_owned()))
                .collect(),
        })
    }
}

mod suite {
    use super::SqliteEngine;

    tablepro_test_support::dump_suite! {
        engine: SqliteEngine,
        docker: false,
    }
}
