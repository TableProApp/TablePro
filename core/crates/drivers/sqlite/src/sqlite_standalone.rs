use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use sqlx::sqlite::SqliteConnection as SqlxConnection;
use tablepro_core::CallResource;

/// A connection opened for one call and closed after it, as a streamed
/// read uses.
#[derive(Debug)]
pub(crate) struct SqliteStandalone {
    connection: SqlxConnection,
    abandon: Arc<AtomicBool>,
}

impl SqliteStandalone {
    pub(crate) fn new(connection: SqlxConnection) -> Self {
        Self {
            connection,
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn connection(&mut self) -> &mut SqlxConnection {
        &mut self.connection
    }
}

impl CallResource for SqliteStandalone {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    /// Dropping the connection ends its worker thread, which closes the
    /// file once the statement it is running has stopped.
    fn discard(self) {}
}
