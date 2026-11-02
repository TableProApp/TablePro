//! The large-table case on SQLite, a test binary of its own because it
//! bounds the process's resident peak. `cargo test` runs the tests of
//! one binary in one process, and the integration target's would count
//! toward the peak. Add no other test here.

#[path = "integration/sqlite_engine.rs"]
mod sqlite_engine;

tablepro_test_support::large_table_conformance_suite! {
    engine: sqlite_engine::SqliteEngine,
    docker: false,
}
