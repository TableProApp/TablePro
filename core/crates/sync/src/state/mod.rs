// The state file on disk (0054, The state file): SQLite in WAL mode, one file per provider and account, bound to its
// identity and held by one process. It neither computes the state MAC nor keeps the anchor (0054, Integrity and
// freshness), so every open reports a fresh file.

mod codec;
mod file;
mod name;

pub use file::{SCHEMA_VERSION, SqliteState, SqliteStateFiles};
pub use name::{state_name, state_path};
