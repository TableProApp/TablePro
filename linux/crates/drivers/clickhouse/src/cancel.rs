use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_core::{
    DriverError, EngineStop, ErrorCategory, LossPhase, StopDelivery, StopReason, StopRequest, StopScope, TimeoutPhase,
};
use uuid::Uuid;

use crate::errors::{code, map_error, server_code};

/// How far a call's KILL QUERY got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopProgress {
    NotSent,
    /// Nothing of the call was running on the server.
    NothingToStop,
    /// The KILL was still out when the call returned.
    InFlight,
    /// The server answered the KILL, so it is reachable.
    Delivered,
    /// The KILL never reached the server.
    Unreachable,
}

/// ClickHouse's KILL QUERY, sent on the sessionless control client.
///
/// It names the query id of the statement the call is running, not the
/// connection, so a late KILL cannot hit what runs after it.
pub(crate) struct ClickHouseStop {
    control: clickhouse::Client,
    running: Mutex<Option<Uuid>>,
    progress: Mutex<StopProgress>,
    withheld: AtomicBool,
}

impl ClickHouseStop {
    pub(crate) fn new(control: clickhouse::Client) -> Self {
        Self {
            control,
            running: Mutex::new(None),
            progress: Mutex::new(StopProgress::NotSent),
            withheld: AtomicBool::new(false),
        }
    }

    /// The statement a stop now names.
    pub(crate) fn track(&self, query_id: Uuid) {
        *lock(&self.running) = Some(query_id);
    }

    /// Nothing the stop may kill is running, as while a write statement
    /// is in flight: killing it would not undo what it already applied.
    pub(crate) fn clear(&self) {
        *lock(&self.running) = None;
    }

    pub(crate) fn progress(&self) -> StopProgress {
        *lock(&self.progress)
    }

    /// The call ended at a stop without sending its next query.
    pub(crate) fn withhold(&self) {
        self.withheld.store(true, Ordering::SeqCst);
    }

    /// Whether the call ended by not sending a query. That was the
    /// driver's own doing, so it says nothing about the route.
    pub(crate) fn withheld(&self) -> bool {
        self.withheld.load(Ordering::SeqCst)
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
impl EngineStop for ClickHouseStop {
    fn delivery(&self) -> StopDelivery {
        StopDelivery::OutOfBand(StopScope::Statement)
    }

    async fn stop(&self) -> Result<(), DriverError> {
        let running = *lock(&self.running);
        let Some(query_id) = running else {
            self.set(StopProgress::NothingToStop);
            return Ok(());
        };
        self.set(StopProgress::InFlight);
        let outcome = kill_query(&self.control, query_id).await;
        self.set(match &outcome {
            Err(error) if unreachable(error) => StopProgress::Unreachable,
            _ => StopProgress::Delivered,
        });
        outcome
    }

    fn acknowledged(&self, error: &DriverError) -> bool {
        self.progress() != StopProgress::NotSent && acknowledges_stop(error)
    }
}

/// Whether the error is the server reporting a KILL taking effect.
pub(crate) fn acknowledges_stop(error: &DriverError) -> bool {
    server_code(error) == Some(code::QUERY_WAS_CANCELLED)
}

/// Stop one query, wherever it runs. The id is bound by the client
/// rather than written into the SQL, so nothing typed elsewhere can
/// change what the KILL matches.
pub(crate) async fn kill_query(control: &clickhouse::Client, query_id: Uuid) -> Result<(), DriverError> {
    control
        .query("KILL QUERY WHERE query_id = ? ASYNC")
        .bind(query_id.to_string())
        .execute()
        .await
        .map_err(|error| map_error(&error))
}

fn unreachable(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Timeout | ErrorCategory::Tls
    )
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

    use super::*;

    #[test]
    fn only_a_394_acknowledges_a_stop() {
        let cancelled = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::ClickHouse { code: 394 }),
            "Code: 394. DB::Exception: Query was cancelled",
        ));
        let other = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::ClickHouse { code: 60 }),
            "Code: 60. DB::Exception: Unknown table",
        ));

        assert!(acknowledges_stop(&cancelled));
        assert!(!acknowledges_stop(&other));
        assert!(!acknowledges_stop(&DriverError::Cancelled));
    }

    #[test]
    fn the_kill_binds_the_query_id_as_a_string_literal() {
        let id = Uuid::nil();

        let sql = clickhouse::Client::default()
            .query("KILL QUERY WHERE query_id = ? ASYNC")
            .bind(id.to_string())
            .sql_display()
            .to_string();

        assert_eq!(
            sql,
            "KILL QUERY WHERE query_id = '00000000-0000-0000-0000-000000000000' ASYNC"
        );
    }
}
