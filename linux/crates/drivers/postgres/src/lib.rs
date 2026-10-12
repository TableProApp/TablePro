//! The PostgreSQL driver: tokio-postgres over the target's transport, a
//! deadpool-postgres workspace pool, and psql-model editor sessions.
//!
//! No statement is ever prepared under a name, so the driver works
//! behind PgBouncer with `max_prepared_statements = 0`, and no session
//! setting is ever sent, so nothing leaks to other clients of a
//! transaction pooler.

mod cancel;
mod capabilities;
mod catalog;
mod codec;
mod commit_resolution;
mod connection;
mod dialect;
mod driver;
mod editor;
mod errors;
mod metadata;
mod pg_call;
mod physical;
mod pool;
mod standalone;
mod stream_read;
mod tls;
mod transport_io;
mod workspace_call;
mod write_batch;

pub use dialect::PgDialect;
pub use driver::PgDriver;
pub use pool::WORKSPACE_POOL_MAX_SIZE;
