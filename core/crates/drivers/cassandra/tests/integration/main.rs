//! Apache Cassandra and ScyllaDB against real servers. Every test that
//! needs one starts its own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod conformance_engine;
mod editor;
mod metadata;
mod paging;
mod round_trip;
mod support;
mod tls;
mod topology;
mod value_corpus;
mod writes;
