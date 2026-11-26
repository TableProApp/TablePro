// Team Library on the service engine against the fake `/v2/sync` server, over the core's Team Library store as the
// apps open it: the publish plan the Swift app had, the edits kept on disk, their discard, the verified delete and the
// import of what 0.88 left unsent (0051, Teams; 0054, The offline queue is on disk).

#![expect(
    clippy::unwrap_used,
    clippy::disallowed_types,
    reason = "the harness fails a test the way the tests do, and record fields compare as JSON values"
)]

#[path = "../engine/harness.rs"]
#[expect(dead_code, reason = "the shared harness carries helpers only the engine tests use")]
mod harness;

mod delete;
mod import;
mod publish;
mod support;
mod unsent;
