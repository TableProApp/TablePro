// The engine core against the fakes of `tablepro-sync-testing`: the in-memory `/v2` server, the state file in memory
// and on disk, and stores as in-memory adapters (0051, Pull, Push, Restore; 0054, The engine, The state file).
#![expect(
    clippy::unwrap_used,
    clippy::disallowed_types,
    reason = "the harness fails a test the way the tests do, and record fields compare as JSON values"
)]

mod epochs;
mod fixtures;
mod harness;
mod history_db;
mod keys;
mod parts;
mod pass;
mod rules;
mod state_file;
mod stop;
