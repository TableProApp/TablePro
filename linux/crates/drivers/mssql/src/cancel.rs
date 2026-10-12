use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_core::{DriverError, EngineStop, LossPhase, StopDelivery, StopReason, StopRequest, TimeoutPhase};

/// How far a call's attention got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopProgress {
    NotSent,
    /// The server answered the attention, or answered something: the
    /// route to it is alive.
    Delivered,
    /// Nothing came back within the cancel budget, so the route itself
    /// is in doubt.
    Failed,
}

/// SQL Server's stop: a TDS attention on the connection the request
/// runs on.
///
/// tiberius borrows the client for the whole request, so only the task
/// that owns it can send the attention, and it does so itself when the
/// call's stop request fires. There is nothing for `OwnedCalls` to send.
#[derive(Debug)]
pub(crate) struct MssqlStop {
    progress: Mutex<StopProgress>,
}

impl MssqlStop {
    pub(crate) fn new() -> Self {
        Self {
            progress: Mutex::new(StopProgress::NotSent),
        }
    }

    pub(crate) fn progress(&self) -> StopProgress {
        *lock(&self.progress)
    }

    pub(crate) fn record(&self, progress: StopProgress) {
        *lock(&self.progress) = progress;
    }
}

#[async_trait]
impl EngineStop for MssqlStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::InBand
    }

    async fn stop(&self) -> Result<(), DriverError> {
        Ok(())
    }

    /// The work returns `Cancelled` only once the server has confirmed
    /// the attention, or once a stop arrived before anything was sent.
    fn acknowledged(&self, error: &DriverError) -> bool {
        matches!(error, DriverError::Cancelled)
    }
}

/// What a stop the server confirmed reads as, for a write, whose result
/// `OwnedCalls` passes through untouched.
pub(crate) fn acknowledged_stop(request: &StopRequest) -> DriverError {
    match request.reason() {
        Some(StopReason::DeadlineElapsed) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        },
        Some(StopReason::Cancelled | StopReason::Shutdown) | None => DriverError::Cancelled,
    }
}

/// What a stop reads as when the server never confirmed it.
pub(crate) fn unconfirmed_stop(request: &StopRequest) -> DriverError {
    match request.reason() {
        Some(StopReason::DeadlineElapsed) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        Some(StopReason::Shutdown) => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        Some(StopReason::Cancelled) | None => DriverError::Cancelled,
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stop_travels_in_band_and_only_cancelled_acknowledges_it() {
        let stop = MssqlStop::new();

        assert_eq!(stop.delivery(), StopDelivery::InBand);
        assert!(stop.acknowledged(&DriverError::Cancelled));
        assert!(!stop.acknowledged(&DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        }));
        assert_eq!(stop.progress(), StopProgress::NotSent);
        stop.record(StopProgress::Failed);
        assert_eq!(stop.progress(), StopProgress::Failed);
    }

    #[test]
    fn a_stop_reads_as_its_reason() {
        let deadline = StopRequest::new();
        deadline.request(StopReason::DeadlineElapsed);
        let shutdown = StopRequest::new();
        shutdown.request(StopReason::Shutdown);

        assert_eq!(
            acknowledged_stop(&deadline),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true
            }
        );
        assert_eq!(
            unconfirmed_stop(&deadline),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            }
        );
        assert!(matches!(
            unconfirmed_stop(&shutdown),
            DriverError::ConnectionLost { .. }
        ));
        assert_eq!(unconfirmed_stop(&StopRequest::new()), DriverError::Cancelled);
    }
}
