use std::sync::Arc;
use std::time::Duration;

use clickhouse::query::Query;
use tablepro_core::statement::Statement;
use tokio::time::Instant;
use uuid::Uuid;

use crate::cancel::ClickHouseStop;
use crate::param_value::bind_params;

/// The client one call sends its queries through, each under a query id
/// of its own that the call's stop can name.
pub(crate) struct CallClient {
    client: clickhouse::Client,
    stop: Arc<ClickHouseStop>,
}

impl CallClient {
    pub(crate) fn new(client: clickhouse::Client, stop: Arc<ClickHouseStop>) -> Self {
        Self { client, stop }
    }

    /// SQL sent as written: a `?` in it is the user's, not a marker.
    pub(crate) fn raw(&self, sql: &str) -> Query {
        self.tracked(self.client.query_raw(sql))
    }

    /// A generated statement, with its values bound as the server-side
    /// parameters its `{pN:Type}` markers name.
    pub(crate) fn statement(&self, statement: &Statement) -> Query {
        bind_params(self.raw(statement.sql()), statement.params())
    }

    /// SQL whose `?` markers the client fills, for identifiers bound
    /// through `clickhouse::sql::Identifier`.
    pub(crate) fn template(&self, sql: &str) -> Query {
        self.tracked(self.client.query(sql))
    }

    fn tracked(&self, query: Query) -> Query {
        let id = Uuid::new_v4();
        self.stop.track(id);
        query.with_setting("query_id", id.to_string())
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
    use super::*;

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
