//! Redis against real servers. Every test that needs one starts its own
//! container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod commands;
mod conformance_engine;
mod support;
mod tls;
