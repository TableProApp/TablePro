use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use sqlx::{AssertSqlSafe, Connection as _, Executor as _};
use tablepro_core::{
    DriverError, EngineStop, LossPhase, StopDelivery, StopReason, StopRequest, StopScope, TimeoutPhase,
};
use tokio_util::sync::CancellationToken;

use crate::errors::{map_error, server_number};
use crate::physical::{MySqlPhysical, MysqlEndpoint, SessionKind, no_limits};

/// ER_NO_SUCH_THREAD: the connection KILL QUERY named is already gone,
/// so there is nothing left running to stop.
const NO_SUCH_THREAD: u16 = 1094;

/// The connection KILL QUERY goes out on, opened the first time a stop
/// needs it and kept for the next.
///
/// It reaches the server over the same route as the connection it
/// stops, so a stop through an SSH forward goes through that forward.
pub(crate) struct ControlLink {
    endpoint: Arc<MysqlEndpoint>,
    connection: tokio::sync::Mutex<Option<MySqlPhysical>>,
}

impl ControlLink {
    pub(crate) fn new(endpoint: Arc<MysqlEndpoint>) -> Self {
        Self {
            endpoint,
            connection: tokio::sync::Mutex::new(None),
        }
    }

    /// Stop whatever the connection `id` is running. The connection is
    /// taken out while it is in use, so a stop abandoned halfway drops
    /// it rather than leaving a half-read answer for the next one.
    pub(crate) async fn kill_query(&self, id: u64) -> Result<(), DriverError> {
        let mut held = self.connection.lock().await;
        let mut physical = match held.take() {
            Some(physical) => physical,
            None => {
                self.endpoint
                    .connect_physical(SessionKind::Control, &no_limits(), &CancellationToken::new())
                    .await?
            }
        };
        let flavour = physical.flavour;
        let killed = physical
            .connection
            .execute(AssertSqlSafe(format!("KILL QUERY {id}")))
            .await
            .map_err(|error| map_error(&error, flavour));
        match killed {
            Ok(_) => {
                *held = Some(physical);
                Ok(())
            }
            Err(error) if server_number(&error) == Some(NO_SUCH_THREAD) => {
                *held = Some(physical);
                Ok(())
            }
            Err(error) => Err(error),
        }
    }

    pub(crate) async fn close(&self) {
        let taken = self.connection.lock().await.take();
        if let Some(physical) = taken {
            let bound = self.endpoint.liveness().close_timeout;
            let _ = tokio::time::timeout(bound, physical.connection.close()).await;
        }
    }
}

/// How far a call's KILL QUERY got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopProgress {
    NotSent,
    /// The call was stopped before it held a connection, so there was no
    /// statement to stop.
    NothingToStop,
    /// The KILL was still out when the call returned: the route did not
    /// open, or the server did not answer it.
    InFlight,
    Delivered,
    Failed,
}

/// KILL QUERY for one call. It names the connection rather than the
/// statement, so one that arrives late can hit whatever runs next there.
pub(crate) struct MySqlStop {
    control: Arc<ControlLink>,
    target: Mutex<Option<u64>>,
    progress: Mutex<StopProgress>,
}

impl MySqlStop {
    pub(crate) fn new(control: Arc<ControlLink>) -> Self {
        Self {
            control,
            target: Mutex::new(None),
            progress: Mutex::new(StopProgress::NotSent),
        }
    }

    /// The connection this call runs on, once it holds one.
    pub(crate) fn arm(&self, connection_id: u64) {
        *lock(&self.target) = Some(connection_id);
    }

    pub(crate) fn progress(&self) -> StopProgress {
        *lock(&self.progress)
    }

    fn set(&self, progress: StopProgress) {
        *lock(&self.progress) = progress;
    }
}

#[async_trait]
impl EngineStop for MySqlStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Connection)
    }

    async fn stop(&self) -> Result<(), DriverError> {
        let target = *lock(&self.target);
        let Some(id) = target else {
            self.set(StopProgress::NothingToStop);
            return Ok(());
        };
        self.set(StopProgress::InFlight);
        let outcome = self.control.kill_query(id).await;
        self.set(match outcome {
            Ok(()) => StopProgress::Delivered,
            Err(_) => StopProgress::Failed,
        });
        outcome
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        acknowledges_stop(error, self.progress())
    }
}

/// Whether the error is the server reporting the stop: 1317 from KILL
/// QUERY, or a statement timeout raised once the KILL had landed.
pub(crate) fn acknowledges_stop(error: &DriverError, progress: StopProgress) -> bool {
    match error {
        DriverError::Cancelled => true,
        DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        } => progress == StopProgress::Delivered,
        _ => false,
    }
}

/// What a call stopped before the server answered reads as.
pub(crate) fn interrupted(request: &StopRequest) -> DriverError {
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
    fn a_server_timeout_acknowledges_only_a_delivered_kill() {
        let timed_out = DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        };

        assert!(acknowledges_stop(&DriverError::Cancelled, StopProgress::Delivered));
        assert!(acknowledges_stop(&timed_out, StopProgress::Delivered));
        assert!(!acknowledges_stop(&timed_out, StopProgress::NotSent));
        assert!(!acknowledges_stop(&DriverError::Busy, StopProgress::Delivered));
    }

    #[test]
    fn a_stop_reads_as_what_asked_for_it() {
        let request = StopRequest::new();
        request.request(StopReason::DeadlineElapsed);

        assert_eq!(
            interrupted(&request),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false
            }
        );
        assert_eq!(interrupted(&StopRequest::new()), DriverError::Cancelled);
    }
}
