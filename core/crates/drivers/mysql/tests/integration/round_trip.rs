//! The export round trip on MySQL and MariaDB: the value corpus out as
//! CSV and as SQL INSERT and back into an empty copy, and a CSV near the
//! import's size limit.

mod mysql_suite {
    use crate::conformance_engine::{MySqlEngine, MysqlServer};

    tablepro_test_support::round_trip_suite! {
        engine: MySqlEngine<MysqlServer>,
        docker: true,
        near_limit: true,
    }
}

mod mariadb_suite {
    use crate::conformance_engine::{MariadbServer, MySqlEngine};

    tablepro_test_support::round_trip_suite! {
        engine: MySqlEngine<MariadbServer>,
        docker: true,
        near_limit: true,
    }
}
