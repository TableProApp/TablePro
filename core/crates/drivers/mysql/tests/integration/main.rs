//! MySQL and MariaDB against real servers. Every test that needs one
//! starts its own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod conformance_engine;
mod csv_import;
mod ddl;
mod decode;
mod dump;
mod editor_session;
mod flavour_suite;
mod lenient_server;
#[cfg(unix)]
mod local_socket;
mod metadata;
mod non_transactional;
mod round_trip;
mod row_limit;
mod server_time_zone;
mod support;
mod tls;
mod user_read;
mod value_corpus;
mod wire_round_trips;
mod write_batch;
