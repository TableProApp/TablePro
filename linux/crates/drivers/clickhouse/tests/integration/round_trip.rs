//! The export round trip on ClickHouse: the value corpus out as CSV and
//! as SQL INSERT and back into an empty copy.

mod suite {
    use crate::conformance_engine::ClickHouseEngine;

    tablepro_test_support::round_trip_suite! {
        engine: ClickHouseEngine,
        docker: true,
        // An import's values travel in the request URL, 8 KiB a
        // statement, so a file near the size limit takes some 8,000
        // statements and minutes longer than the case may run.
        near_limit: false,
    }
}
