//! The DuckDB driver: one database file, opened once per process, with
//! a pool of connections to it for the workspace and a connection of
//! its own for each editor tab and each streamed read.

mod capabilities;
mod catalog;
mod connection;
mod create_file;
mod ddl;
mod decode;
mod dialect;
mod driver;
mod duck_type;
mod editor_session;
mod encode;
mod errors;
mod instance;
mod pool;
mod result_stream;
mod stop;
mod transaction_state;
mod write_batch;

pub use dialect::DuckDbDialect;
pub use driver::DuckDbDriver;
pub use pool::WORKSPACE_POOL_MAX_SIZE;
