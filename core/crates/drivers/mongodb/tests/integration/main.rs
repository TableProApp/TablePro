//! MongoDB against real servers. Every test that needs one starts its
//! own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod catalog;
mod conformance_engine;
mod export;
mod replica_set;
mod seed_list;
mod statements;
mod stop;
mod support;
mod tls;
