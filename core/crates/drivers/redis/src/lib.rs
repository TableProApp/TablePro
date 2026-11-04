//! The Redis driver: redis-rs over a stream the target's transport
//! opens, wrapped in TLS here so rustls stays on aws-lc-rs.
//!
//! Redis has no SQL. The workspace reads keys with `SCAN` and a key's
//! value a window at a time by its type; the editor sends one command per
//! line. Every link is a multiplexed connection: the workspace shares
//! one, and each editor tab and each export has its own, so a command
//! that blocks or runs long holds nothing else up.

mod capabilities;
mod connection;
mod dialect;
mod driver;
mod editor_run;
mod editor_session;
mod endpoint;
mod errors;
mod key_name;
mod key_read;
mod key_scan;
mod link;
mod reply_rows;
mod server_version;
mod session_status;
mod stream_read;
mod tls_watch;
mod workspace_link;

pub use dialect::RedisDialect;
pub use driver::RedisDriver;
pub use key_name::{key_bytes, key_text};
