//! PostgreSQL against real servers. Every test that needs one starts
//! its own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod cancellation;
mod conformance_engine;
mod decode;
mod editor_session;
mod liveness;
mod metadata;
mod pgbouncer;
mod read_only;
mod support;
mod tls;
mod write_batch;
