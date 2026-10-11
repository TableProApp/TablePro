use std::time::Duration;

use tablepro_core::OperationControl;
use tokio_util::sync::CancellationToken;

use crate::services::preferences::PreferencesStore;

/// The query timeout the user configured, read on the GTK thread so the
/// deadline itself can be built inside the async command where the tokio
/// clock lives. A configured `0` means no timeout, which is how the SQL
/// editor has always read the same preference.
pub fn configured_timeout_secs(preferences: &PreferencesStore) -> u32 {
    preferences.load().query_timeout_secs
}

pub fn timeout_for(
    preferences: &PreferencesStore,
    database: &crate::services::database_service::DatabaseService,
    connection: Option<uuid::Uuid>,
) -> u32 {
    let own = connection
        .and_then(|id| database.metadata(id))
        .and_then(|metadata| metadata.query_timeout_secs);
    effective_timeout(own, configured_timeout_secs(preferences))
}

fn effective_timeout(own: Option<u32>, global: u32) -> u32 {
    own.unwrap_or(global)
}

pub fn deadline_for(timeout_secs: u32) -> Option<tokio::time::Instant> {
    (timeout_secs > 0).then(|| tokio::time::Instant::now() + Duration::from_secs(u64::from(timeout_secs)))
}

/// A control carrying only the configured deadline. Used by the paths
/// that have no Stop button of their own: browse loads, row counts,
/// structure reads and DDL, activity, and EXPLAIN. Without it those
/// operations run unbounded.
pub fn bounded(timeout_secs: u32) -> OperationControl {
    OperationControl::new(CancellationToken::new(), deadline_for(timeout_secs))
}

pub fn bounded_with(timeout_secs: u32, token: CancellationToken) -> OperationControl {
    OperationControl::new(token, deadline_for(timeout_secs))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connection_timeout_overrides_the_global_preference() {
        assert_eq!(effective_timeout(Some(5), 60), 5);
        assert_eq!(effective_timeout(None, 60), 60);
    }

    #[tokio::test]
    async fn a_zero_timeout_means_no_deadline() {
        assert!(deadline_for(0).is_none());
        assert!(bounded(0).deadline().is_none());
    }

    #[tokio::test]
    async fn a_configured_timeout_becomes_a_deadline_in_the_future() {
        let before = tokio::time::Instant::now();
        let deadline = deadline_for(30).expect("a positive timeout must produce a deadline");
        assert!(deadline > before);
        assert!(deadline <= before + Duration::from_secs(31));
    }

    #[tokio::test]
    async fn a_supplied_token_is_the_one_the_control_carries() {
        let token = CancellationToken::new();
        let control = bounded_with(0, token.clone());
        assert!(!control.cancellation_token().is_cancelled());
        token.cancel();
        assert!(control.cancellation_token().is_cancelled());
    }
}
