use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use sqlx::Sqlite;
use sqlx::pool::PoolConnection;
use sqlx::sqlite::SqliteConnection as SqlxConnection;
use tablepro_core::CallResource;

/// The workspace connection, held for one call.
///
/// sqlx keeps nothing of ours on a pooled connection that a pool hook
/// could read back, so the call's abandon flag travels with the hold:
/// a connection whose call was abandoned, or that a call asked to
/// discard, is closed when the hold ends instead of going back to the
/// pool with a statement or a suspended setting still on it.
#[derive(Debug)]
pub(crate) struct SqlitePooled {
    connection: PoolConnection<Sqlite>,
    abandon: Arc<AtomicBool>,
}

impl SqlitePooled {
    pub(crate) fn new(connection: PoolConnection<Sqlite>) -> Self {
        Self {
            connection,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn connection(&mut self) -> &mut SqlxConnection {
        &mut self.connection
    }

    /// Close the connection when the call ends, for a call that left it
    /// in a state the next one must not inherit.
    pub(crate) fn discard_on_release(&mut self) {
        self.connection.close_on_drop();
    }
}

impl CallResource for SqlitePooled {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(mut self) {
        self.discard_on_release();
    }
}

impl Drop for SqlitePooled {
    fn drop(&mut self) {
        if self.abandon.load(Ordering::SeqCst) {
            self.connection.close_on_drop();
        }
    }
}
