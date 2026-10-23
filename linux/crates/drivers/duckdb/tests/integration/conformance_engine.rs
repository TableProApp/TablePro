//! The connection and DDL conformance suites on DuckDB.

use crate::duckdb_engine::DuckDbEngine;

tablepro_test_support::ddl_conformance_suite! {
    engine: DuckDbEngine,
    docker: false,
}

// DuckDB has no server statement timeout, so no case bounds DDL by one.
tablepro_test_support::connection_conformance_suite! {
    engine: DuckDbEngine,
    docker: false,
    endpoint: file,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: true,
    bounded_ddl: false,
}
