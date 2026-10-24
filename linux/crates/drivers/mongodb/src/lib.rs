//! The MongoDB driver: the mongodb crate, with rustls on aws-lc-rs.
//!
//! A database is a schema and a collection a table: a collection opens
//! in a table tab, its fields as columns, read and written through the
//! shell statements `tablepro_core::document` builds. The editor takes
//! the same shell language. Over a direct route the client library
//! dials the servers and sets up TLS against the system store; through
//! an SSH forward it dials a relay whose streams come from the
//! transport, wrapped in TLS here.

mod call;
mod capabilities;
mod catalog;
mod cells;
mod client_tls;
mod connect_watch;
mod connection;
mod cursor_rows;
mod dialect;
mod driver;
mod editor_run;
mod editor_session;
mod endpoint;
mod errors;
mod execute;
mod extended_json;
mod field_types;
mod relay;
mod rows;
mod server_version;
mod session_status;
mod shell_command;
mod shell_find;
mod shell_write;
mod stream_read;
mod to_bson;
mod write_batch;

pub use dialect::MongoDialect;
pub use driver::MongoDriver;
