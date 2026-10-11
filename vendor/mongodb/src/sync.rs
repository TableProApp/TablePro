//! Contains the sync API. This is only available when the `sync` feature is enabled.

mod change_stream;
mod client;
mod coll;
mod db;
pub mod gridfs;

#[cfg(test)]
mod test;

pub use crate::cursor::sync::{Cursor, SessionCursor, SessionCursorIter};
pub use change_stream::{ChangeStream, SessionChangeStream};
pub use client::{session::ClientSession, Client};
pub use coll::Collection;
pub use db::Database;

#[cfg(feature = "sync")]
pub(crate) static TOKIO_RUNTIME: std::sync::LazyLock<tokio::runtime::Runtime> =
    std::sync::LazyLock::new(|| match tokio::runtime::Runtime::new() {
        Ok(runtime) => runtime,
        Err(err) => panic!("Error occurred when starting the underlying async runtime: {err}"),
    });
