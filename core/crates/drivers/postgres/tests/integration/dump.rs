//! The dump round trip on PostgreSQL: the sample out as a SQL file, into
//! an empty database through the SQL file import, and out again the same.

mod suite {
    use crate::conformance_engine::PgEngine;

    tablepro_test_support::dump_suite! {
        engine: PgEngine,
        docker: true,
    }
}
