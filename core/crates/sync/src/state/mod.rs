// The state file on disk (0054, The state file): SQLite in WAL mode, one file per provider and account, bound to its
// identity and held by one process, sealed by the state MAC and anchored in the device store (Integrity and freshness).

mod codec;
mod file;
pub mod integrity;
mod name;

pub(crate) use codec::held_reason_name;
pub use file::{SCHEMA_VERSION, SqliteState, SqliteStateFiles};
pub use name::{state_name, state_path};
