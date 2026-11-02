use std::time::Duration;

use crate::QueryTimeout;

/// What every workspace call on a connection runs under.
///
/// The limits are the server's, set on the session or per call, so a
/// statement the app has given up on stops on the server too rather
/// than holding its locks until it finishes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkspaceSettings {
    pub read_only: bool,
    pub statement_timeout: Duration,
    /// How long a statement waits for a lock before it fails, kept
    /// shorter than the statement timeout so a blocked edit reports the
    /// lock rather than a generic timeout.
    pub lock_timeout: Duration,
    /// The limit on the connection's editor runs, which the server
    /// enforces too where the engine can.
    pub editor_timeout: QueryTimeout,
}

impl WorkspaceSettings {
    pub const STATEMENT_TIMEOUT: Duration = Duration::from_secs(60);
    pub const LOCK_TIMEOUT: Duration = Duration::from_secs(10);

    pub fn workspace(read_only: bool) -> Self {
        Self {
            read_only,
            statement_timeout: Self::STATEMENT_TIMEOUT,
            lock_timeout: Self::LOCK_TIMEOUT,
            editor_timeout: QueryTimeout::Preference,
        }
    }

    pub fn with_editor_timeout(self, editor_timeout: QueryTimeout) -> Self {
        Self { editor_timeout, ..self }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_workspace_waits_a_minute_for_a_statement_and_ten_seconds_for_a_lock() {
        let settings = WorkspaceSettings::workspace(true);

        assert!(settings.read_only);
        assert_eq!(settings.statement_timeout, Duration::from_secs(60));
        assert_eq!(settings.lock_timeout, Duration::from_secs(10));
        assert_eq!(settings.editor_timeout, QueryTimeout::Preference);
        assert!(!WorkspaceSettings::workspace(false).read_only);
    }
}
