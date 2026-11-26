// The state file's integrity and freshness (0054, Integrity and freshness; Verification): the digests and the state
// MAC, the anchor's two steps around each commit, what an open finds against the anchor, and the rebuild of a stale
// file's key tables through the key flows and the engine.

#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]
#![expect(
    clippy::disallowed_types,
    reason = "the key flows take and give JSON as serde values, which compare as values whatever the member order"
)]

mod digests;
mod freshness;
mod rebuild;
mod support;
mod transitions;
