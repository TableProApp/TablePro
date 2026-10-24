//! Stopping a statement DuckDB is running.
//!
//! `duckdb_interrupt` sets a flag on the connection that the statement
//! running there checks as it works, and the statement fails with an
//! interrupt error. DuckDB clears the flag as each statement starts, so
//! a stop sent while the work is between statements would be lost: the
//! stop is sent again until the work returns or holds stops off for its
//! cleanup. The flag names the connection, not the statement, so the
//! connection of a call it may have missed is not reused.

use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{DriverError, EngineStop, StopDelivery, StopScope};

use crate::errors::is_interrupt;
use crate::instance::StopHandle;

/// How often a stop is sent again while the work it is for still runs.
const RESEND: Duration = Duration::from_millis(10);

/// One call's stop. It is armed once the call holds a connection; a
/// stop asked for before that finds nothing to interrupt, and the call
/// sees the request before it sends anything.
#[derive(Default)]
pub(crate) struct DuckStop {
    armed: Mutex<Option<StopHandle>>,
}

impl DuckStop {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn arm(&self, handle: Option<StopHandle>) {
        *self.armed.lock().unwrap_or_else(PoisonError::into_inner) = handle;
    }

    fn armed(&self) -> Option<StopHandle> {
        self.armed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

/// Interrupt the connection until the work on it no longer takes stops.
pub(crate) async fn interrupt_until_settled(handle: &StopHandle) {
    while handle.is_stoppable() {
        handle.interrupt();
        tokio::time::sleep(RESEND).await;
    }
}

#[async_trait]
impl EngineStop for DuckStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Connection)
    }

    /// Settles once the work has given way or holds stops off.
    async fn stop(&self) -> Result<(), DriverError> {
        if let Some(handle) = self.armed() {
            interrupt_until_settled(&handle).await;
        }
        Ok(())
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        is_interrupt(error)
    }
}
