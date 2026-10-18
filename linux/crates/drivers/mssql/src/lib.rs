//! The SQL Server driver: tiberius over the target's transport, a
//! deadpool workspace pool, and editor sessions on connections of their
//! own.
//!
//! tiberius borrows its client for the whole of a request, so nothing
//! outside the task that owns the client can stop one. Every stop is
//! therefore sent in band, as a TDS attention, by that task, and a
//! connection whose response may be half read is discarded rather than
//! reused.

mod cancel;
mod capabilities;
mod catalog;
mod connection;
mod ddl;
mod decode;
mod dialect;
mod driver;
mod editor_run;
mod editor_session;
mod encode;
mod endpoint;
mod errors;
mod in_band_request;
mod login;
mod metadata;
mod mssql_manager;
mod mssql_pooled;
mod physical;
mod read_only_guard;
mod standalone;
mod stream_read;
mod tds_message;
mod tls_config;
mod transport_io;
mod workspace_call;
mod write_batch;

pub use dialect::MssqlDialect;
pub use driver::MssqlDriver;
pub use mssql_manager::WORKSPACE_POOL_MAX_SIZE;
