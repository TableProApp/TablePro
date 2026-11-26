// The CloudKit engine against the fake zone (0054, Verification): fetch and merge, the held and deferred sets,
// deletions a full fetch finds, token expiry, refill, both crash windows, the push and its outcomes, a removed zone and
// Upload Again, an account switch, the values that wait for the person, and the Swift engine's metadata.
#![expect(
    clippy::disallowed_types,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]
#![expect(
    clippy::unwrap_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

mod account;
mod approval;
mod faults;
mod full;
mod held;
mod legacy;
mod merge;
mod pass;
mod pending;
mod pull;
mod push;
mod support;
mod zone;
