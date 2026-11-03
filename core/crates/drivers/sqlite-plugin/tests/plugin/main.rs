#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod matrix;
mod store;
mod support;
