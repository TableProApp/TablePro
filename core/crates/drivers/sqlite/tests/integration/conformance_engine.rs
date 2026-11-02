//! The connection and DDL conformance suites on SQLite.

use crate::sqlite_engine::SqliteEngine;

tablepro_test_support::ddl_conformance_suite! {
    engine: SqliteEngine,
    docker: false,
}

// Every stored value is one of five storage classes and all five are
// decoded, so there is no unsupported type to list. SQLite has no
// server statement timeout, so no case bounds DDL by one.
tablepro_test_support::connection_conformance_suite! {
    engine: SqliteEngine,
    docker: false,
    endpoint: file,
    server_stop: true,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: false,
    bounded_ddl: false,
}
