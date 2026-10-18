use std::sync::Arc;
use std::time::Duration;

use clickhouse::query::Query;
use tablepro_core::statement::Statement;
use tablepro_core::{DriverError, StopRequest};
use tokio::time::Instant;
use uuid::Uuid;

use crate::cancel::ClickHouseStop;
use crate::param_value::bind_params;

/// The client one call sends its queries through, each under a query id
/// of its own that the call's stop can name.
///
/// A KILL stops only the query running when it arrives, so a call of
/// several queries would go on to the next one after a stop. Once the
/// call is stopped, no further query is handed out.
pub(crate) struct CallClient {
    client: clickhouse::Client,
    stop: Arc<ClickHouseStop>,
    request: StopRequest,
}

impl CallClient {
    pub(crate) fn new(client: clickhouse::Client, stop: Arc<ClickHouseStop>, request: StopRequest) -> Self {
        Self { client, stop, request }
    }

    /// SQL sent as written: a `?` in it is the user's, not a marker.
    pub(crate) fn raw(&self, sql: &str) -> Result<Query, DriverError> {
        self.tracked(self.client.query_raw(sql))
    }

    /// A generated statement, with its values bound as the server-side
    /// parameters its `{pN:Type}` markers name.
    pub(crate) fn statement(&self, statement: &Statement) -> Result<Query, DriverError> {
        Ok(bind_params(self.raw(statement.sql())?, statement.params()))
    }

    /// SQL whose `?` markers the client fills, for identifiers bound
    /// through `clickhouse::sql::Identifier`.
    pub(crate) fn template(&self, sql: &str) -> Result<Query, DriverError> {
        self.tracked(self.client.query(sql))
    }

    fn tracked(&self, query: Query) -> Result<Query, DriverError> {
        if self.request.is_requested() {
            self.stop.withhold();
            return Err(self.stop.interrupted(&self.request));
        }
        let id = Uuid::new_v4();
        self.stop.track(id);
        Ok(query.with_setting("query_id", id.to_string()))
    }
}

/// A read as the server runs it: never a write, and stopped by the
/// server itself once its bound passes. `None` leaves it unbounded.
pub(crate) fn reading(client: &clickhouse::Client, bound: Option<Duration>) -> clickhouse::Client {
    client
        .clone()
        .with_setting("readonly", "2")
        .with_setting("timeout_overflow_mode", "throw")
        .with_setting("max_execution_time", whole_seconds(bound).to_string())
}

/// The nearer of the call's deadline and the configured timeout.
pub(crate) fn read_bound(deadline: Option<Instant>, configured: Option<Duration>) -> Option<Duration> {
    let remaining = deadline.map(|deadline| deadline.saturating_duration_since(Instant::now()));
    match (remaining, configured) {
        (Some(remaining), Some(configured)) => Some(remaining.min(configured)),
        (remaining, configured) => remaining.or(configured),
    }
}

/// `max_execution_time` in whole seconds, rounded up so the server never
/// stops a read before the app would, and at least one, since zero is
/// the server's "no limit".
pub(crate) fn whole_seconds(bound: Option<Duration>) -> u64 {
    match bound {
        None => 0,
        Some(bound) => {
            let rounded = bound.as_secs() + u64::from(bound.subsec_nanos() > 0);
            rounded.max(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::StopReason;

    use super::*;

    fn call(request: &StopRequest) -> (CallClient, Arc<ClickHouseStop>) {
        let stop = Arc::new(ClickHouseStop::new(clickhouse::Client::default()));
        let calls = CallClient::new(clickhouse::Client::default(), stop.clone(), request.clone());
        (calls, stop)
    }

    #[test]
    fn a_query_goes_out_until_the_call_is_stopped() {
        let request = StopRequest::new();
        let (calls, stop) = call(&request);

        assert!(calls.raw("SELECT 1").is_ok());
        assert!(!stop.withheld());
        request.request(StopReason::Cancelled);

        assert_eq!(calls.raw("SELECT 2").err(), Some(DriverError::Cancelled));
        assert!(calls.template("SHOW CREATE TABLE ?.?").is_err());
        assert!(stop.withheld());
    }

    #[test]
    fn a_withheld_query_reads_as_what_stopped_the_call() {
        let request = StopRequest::new();
        let (calls, _stop) = call(&request);

        request.request(StopReason::DeadlineElapsed);

        assert_eq!(
            calls.raw("SELECT 1").err(),
            Some(DriverError::Timeout {
                phase: tablepro_core::TimeoutPhase::Statement,
                server_cancelled: false,
            })
        );
    }

    #[test]
    fn a_bound_rounds_up_to_whole_seconds_and_never_reaches_zero() {
        assert_eq!(whole_seconds(None), 0);
        assert_eq!(whole_seconds(Some(Duration::from_millis(1))), 1);
        assert_eq!(whole_seconds(Some(Duration::ZERO)), 1);
        assert_eq!(whole_seconds(Some(Duration::from_millis(1_500))), 2);
        assert_eq!(whole_seconds(Some(Duration::from_secs(60))), 60);
    }

    #[tokio::test(start_paused = true)]
    async fn the_nearer_bound_wins() {
        let deadline = Instant::now() + Duration::from_secs(5);

        assert_eq!(
            read_bound(Some(deadline), Some(Duration::from_secs(60))),
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            read_bound(None, Some(Duration::from_secs(60))),
            Some(Duration::from_secs(60))
        );
        assert_eq!(read_bound(None, None), None);
    }
}
