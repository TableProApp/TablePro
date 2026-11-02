//! The export round trip on DuckDB: the value corpus out as CSV and as
//! SQL INSERT and back into an empty copy, and a CSV near the import's
//! size limit. No server is needed, so it runs in the unit suite.

use crate::duckdb_engine::DuckDbEngine;

tablepro_test_support::round_trip_suite! {
    engine: DuckDbEngine,
    docker: false,
    near_limit: true,
}
