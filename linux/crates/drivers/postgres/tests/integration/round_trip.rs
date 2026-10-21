//! The export round trip on PostgreSQL: the value corpus out as CSV and
//! as SQL INSERT and back into an empty copy, and a CSV near the import's
//! size limit.

mod suite {
    use crate::conformance_engine::PgEngine;

    tablepro_test_support::round_trip_suite! {
        engine: PgEngine,
        docker: true,
        near_limit: true,
    }
}
