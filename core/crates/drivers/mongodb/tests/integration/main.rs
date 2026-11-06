//! MongoDB against real servers. Every test that needs one starts its
//! own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod catalog;
mod conformance_engine;
mod statements;
mod support;
mod tls;
