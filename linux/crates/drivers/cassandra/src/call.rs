//! How a CQL call runs under `OwnedCalls`.
//!
//! The native protocol has no message that stops a request the server
//! is running: a request is a stream id on a shared connection, and the
//! server answers it whenever it is done. So a stopped call drops its
//! request and returns at once. The client library sets the stream id
//! aside until the late answer arrives, the connection keeps serving
//! every other call, and the server runs the statement to its own
//! timeout.

use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use async_trait::async_trait;
use tablepro_core::{
    CallResource, DriverError, EngineStop, LossPhase, StopDelivery, StopReason, StopRequest, TimeoutPhase,
};

/// What one call holds: nothing of its own, since every call shares the
/// session's multiplexed connection, so there is nothing to discard.
pub(crate) struct CqlCall {
    abandon: Arc<AtomicBool>,
}

impl CqlCall {
    pub(crate) fn new() -> Self {
        Self {
            abandon: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl CallResource for CqlCall {
    fn abandon_flag(&self) -> Arc<AtomicBool> {
        self.abandon.clone()
    }

    fn discard(self) {}
}

/// The stop is the work dropping its request, carried in band: nothing
/// goes to the server, so nothing can arrive late, and the server never
/// acknowledges anything.
pub(crate) struct CqlStop;

#[async_trait]
impl EngineStop for CqlStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::InBand
    }

    async fn stop(&self) -> Result<(), DriverError> {
        Ok(())
    }

    fn acknowledged(&self, _error: &DriverError) -> bool {
        false
    }
}

/// `work`, or what stopped the call as soon as it is stopped.
pub(crate) async fn stoppable<T>(
    request: &StopRequest,
    work: impl Future<Output = Result<T, DriverError>>,
) -> Result<T, DriverError> {
    tokio::select! {
        biased;
        () = request.requested() => Err(stopped(request)),
        result = work => result,
    }
}

/// A stopped call reads as what stopped it. The server was never told,
/// so a deadline is never a statement the server cancelled.
pub(crate) fn stopped(request: &StopRequest) -> DriverError {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_stop_ends_the_work_with_what_stopped_it() {
        let request = StopRequest::new();
        request.request(StopReason::DeadlineElapsed);

        let outcome = stoppable(&request, std::future::pending::<Result<(), DriverError>>()).await;

        assert_eq!(
            outcome,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            })
        );
    }

    #[tokio::test]
    async fn work_that_finishes_first_keeps_its_result() {
        let request = StopRequest::new();

        assert_eq!(stoppable(&request, async { Ok(7) }).await, Ok(7));
        assert!(!CqlStop.acknowledged(&DriverError::Cancelled));
        assert_eq!(CqlStop.delivery(), StopDelivery::InBand);
    }
}
