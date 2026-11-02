//! SQL Server against a real server. Every test that needs one starts
//! its own container and is ignored without Docker; SQL Server publishes
//! no arm64 image, so these run in CI.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod cancellation;
mod conformance_engine;
mod csv_import;
mod ddl;
mod decode;
mod filter;
mod identity_insert;
mod metadata;
mod read_only;
mod round_trip;
mod sessions;
mod support;
mod tls;
mod value_corpus;
mod write_batch;
