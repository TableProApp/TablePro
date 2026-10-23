//! The export round trip on both servers: the value corpus out as CSV
//! and as SQL INSERT and back into an empty copy.

// An import writes a row a statement, each proved by a lightweight
// transaction or a probe, so a file near the size limit takes some
// 315,000 round trips and far longer than the case may run.
mod cassandra_suite {
    use crate::conformance_engine::CqlEngine;
    use crate::support::CassandraServer;

    tablepro_test_support::round_trip_suite! {
        engine: CqlEngine<CassandraServer>,
        docker: true,
        near_limit: false,
    }
}

mod scylla_suite {
    use crate::conformance_engine::CqlEngine;
    use crate::support::ScyllaServer;

    tablepro_test_support::round_trip_suite! {
        engine: CqlEngine<ScyllaServer>,
        docker: true,
        near_limit: false,
    }
}
