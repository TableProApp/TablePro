//! The SQLite driver: one database file, one workspace connection, and
//! an editor session per tab on a connection of its own.

mod autocommit;
mod capabilities;
mod catalog;
mod connection;
mod create_file;
mod ddl;
mod deadline;
mod decode;
mod dialect;
mod driver;
mod editor_session;
mod encode;
mod errors;
mod foreign_key_verification;
mod index_sql;
mod interrupt;
mod lock_wait;
mod metadata;
mod open;
mod result_stream;
mod sqlite_pooled;
mod sqlite_standalone;
mod write_batch;

pub use catalog::{SQLITE_MIN_VERSION, SqliteVersion, check_runtime_version};
pub use dialect::SqliteDialect;
pub use driver::{SqliteDriver, WORKSPACE_POOL_MAX_SIZE};
