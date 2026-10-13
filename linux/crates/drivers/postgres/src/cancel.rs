use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_core::{
    DriverError, EngineStop, LossPhase, StopDelivery, StopReason, StopRequest, StopScope, TimeoutPhase,
};
use tokio_postgres::CancelToken;

use crate::errors::{QUERY_CANCELED, sqlstate};
use crate::physical::PgEndpoint;

/// How far a call's cancel request got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopProgress {
    NotSent,
    /// The call was stopped before it held a connection, so there was no
    /// backend to cancel.
    NothingToStop,
    /// The request was still out when the call returned: the transport
    /// did not open, or the server did not answer it.
    InFlight,
    Delivered,
    Failed,
}

/// PostgreSQL's cancel request: a second connection naming the backend's
/// pid and secret key. It names the connection, not the statement, so a
/// late one can hit whatever runs next there.
pub(crate) struct PgStop {
    endpoint: Arc<PgEndpoint>,
    token: Mutex<Option<CancelToken>>,
    progress: Mutex<StopProgress>,
}

impl PgStop {
    pub(crate) fn new(endpoint: Arc<PgEndpoint>) -> Self {
        Self {
            endpoint,
            token: Mutex::new(None),
            progress: Mutex::new(StopProgress::NotSent),
        }
    }

    /// The backend this call runs on, once it holds one.
    pub(crate) fn arm(&self, token: CancelToken) {
        *lock(&self.token) = Some(token);
    }

    pub(crate) fn progress(&self) -> StopProgress {
        *lock(&self.progress)
    }

    /// What a call stopped before it reached the server reads as.
    pub(crate) fn interrupted(&self, request: &StopRequest) -> DriverError {
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

    fn set(&self, progress: StopProgress) {
        *lock(&self.progress) = progress;
    }
}

#[async_trait]
impl EngineStop for PgStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Connection)
    }

    async fn stop(&self) -> Result<(), DriverError> {
        let token = lock(&self.token).clone();
        let Some(token) = token else {
            self.set(StopProgress::NothingToStop);
            return Ok(());
        };
        self.set(StopProgress::InFlight);
        let outcome = self.endpoint.cancel_request(&token).await;
        self.set(match outcome {
            Ok(()) => StopProgress::Delivered,
            Err(_) => StopProgress::Failed,
        });
        outcome
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        acknowledges_stop(error)
    }
}

/// Whether the server answered a statement with 57014, which is how it
/// reports a cancel request or a statement timeout taking effect.
pub(crate) fn acknowledges_stop(error: &DriverError) -> bool {
    sqlstate(error) == Some(QUERY_CANCELED)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

    use super::*;

    #[test]
    fn a_57014_in_either_form_acknowledges_the_stop() {
        let cancelled = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::SqlState("57014".to_owned())),
            "canceling statement due to user request",
        ));
        let timed_out = DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        };

        assert!(acknowledges_stop(&cancelled));
        assert!(acknowledges_stop(&timed_out));
        assert!(!acknowledges_stop(&DriverError::Cancelled));
    }
}
