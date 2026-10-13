//! Stopping a statement SQLite is running.
//!
//! The progress handler is the only way in. `lock_handle` waits for the
//! worker thread to finish its current command, so `sqlite3_interrupt`
//! through it would arrive only once the statement it was meant to stop
//! had ended. The handler runs on the worker thread itself, between
//! virtual machine instructions, and stops the statement when the call
//! has raised its flag. A statement still waiting for another
//! connection's lock runs no instructions, so the lock wait checks the
//! same flag (`lock_wait`).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use sqlx::sqlite::SqliteConnection as SqlxConnection;
use tablepro_core::{DriverError, EngineStop, StopDelivery, StopScope};

use crate::errors::{is_interrupt, map_error};
use crate::lock_wait::LockWait;

/// How many virtual machine instructions run between two looks at the
/// flag: often enough that a stop lands within milliseconds, rarely
/// enough to cost nothing measurable.
const INSTRUCTIONS_PER_CHECK: i32 = 1000;

/// One call's stop. Each call installs a fresh one, so a stop that
/// arrives late can never reach the next call on the connection.
#[derive(Debug, Clone, Default)]
pub(crate) struct InterruptFlag(Arc<AtomicBool>);

impl InterruptFlag {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn raise(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Let the statements that clean up after a stop run: a rollback
    /// must not be interrupted by the stop that caused it.
    pub(crate) fn lower(&self) {
        self.0.store(false, Ordering::SeqCst);
    }

    pub(crate) fn is_raised(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// Whether `error` is SQLite giving way to this flag: a running
    /// statement is interrupted, and one waiting for a lock gives up
    /// as busy.
    pub(crate) fn stopped(&self, error: &DriverError) -> bool {
        is_interrupt(error) || (self.is_raised() && *error == DriverError::Busy)
    }

    /// Make this flag the one the connection's statements answer to,
    /// with `lock_timeout` as the longest wait for another connection's
    /// lock.
    pub(crate) async fn install(
        &self,
        connection: &mut SqlxConnection,
        lock_timeout: Duration,
    ) -> Result<(), DriverError> {
        let wait = Arc::new(LockWait::new(self.0.clone(), lock_timeout));
        let mut handle = connection.lock_handle().await.map_err(map_error)?;
        wait.install(&mut handle)?;
        // The progress handler owns the wait, so it lives exactly as long
        // as this call's statements can ask for it.
        handle.set_progress_handler(INSTRUCTIONS_PER_CHECK, move || !wait.stopped());
        Ok(())
    }
}

/// The stop `OwnedCalls` sends: raise the call's flag. It names the
/// call, not the connection, so nothing can arrive late.
#[derive(Debug)]
pub(crate) struct SqliteStop {
    flag: InterruptFlag,
}

impl SqliteStop {
    pub(crate) fn new(flag: InterruptFlag) -> Self {
        Self { flag }
    }
}

#[async_trait]
impl EngineStop for SqliteStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Statement)
    }

    async fn stop(&self) -> Result<(), DriverError> {
        self.flag.raise();
        Ok(())
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        self.flag.stopped(error) || matches!(error, DriverError::RolledBack { source, .. } if self.flag.stopped(source))
    }
}
