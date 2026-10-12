//! MySQL and MariaDB against real servers. Every test that needs one
//! starts its own container and is ignored without Docker.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod conformance_engine;
mod decode;
mod editor_session;
mod flavour_suite;
mod metadata;
mod non_transactional;
mod row_limit;
mod support;
mod tls;
