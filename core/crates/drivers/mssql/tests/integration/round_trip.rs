//! The export round trip on SQL Server: the value corpus out as CSV and
//! as SQL INSERT and back into an empty copy, and a CSV near the import's
//! size limit.

mod suite {
    use crate::conformance_engine::MssqlEngine;

    tablepro_test_support::round_trip_suite! {
        engine: MssqlEngine,
        docker: true,
        near_limit: true,
    }
}
