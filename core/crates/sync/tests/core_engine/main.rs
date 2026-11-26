// The engine and the key flows together, as the apps run them: one `KeyService` is the engine's key flows and the
// source of its proofs, and its hooks are the engine's, against the fake `/v2/sync` server.

#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]
#![expect(
    clippy::disallowed_types,
    reason = "the key flows take and give JSON as serde values, which compare as values whatever the member order"
)]

#[path = "../account_keys/harness.rs"]
#[expect(dead_code, reason = "the shared harness carries helpers only the account tests use")]
mod harness;

mod device;
mod push_back;
mod replay;
