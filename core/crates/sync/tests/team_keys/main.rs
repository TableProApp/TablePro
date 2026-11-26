// K7-3's team flows end to end against the fake server, on devices that ran K7-1's genesis: a team created, a member
// copied in and confirmed, envelopes sealed and opened across members, a rotation after a member leaves, and the
// refusals a device makes before it sends anything.

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

mod flows;
mod hostile;
