use std::path::PathBuf;

use thiserror::Error;

use crate::commit::CommitToken;
use crate::config_error::ConfigError;
use crate::error_category::ErrorCategory;
use crate::loss_phase::LossPhase;
use crate::read_only_refusal::ReadOnlyRefusal;
use crate::server_diagnostics::ServerDiagnostics;
use crate::timeout_phase::TimeoutPhase;
use crate::tls_failure::TlsFailure;
use crate::transport_error::TransportError;
use crate::write_report::StatementOutcome;

/// What a driver could not do, in enough detail for the app to say
/// what to try next.
///
/// The three write variants are the reason this is not a flat list of
/// messages. After a write fails, the only question that matters is
/// what is now in the database, and `RolledBack`, `PartiallyApplied`
/// and `CommitOutcomeUnknown` are three different answers.
#[derive(Debug, Clone, PartialEq, Error)]
#[non_exhaustive]
pub enum DriverError {
    #[error(transparent)]
    Transport(#[from] TransportError),

    #[error("the server refused the credentials{}", diagnostics.as_ref().map(|d| format!(": {d}")).unwrap_or_default())]
    Auth {
        diagnostics: Option<Box<ServerDiagnostics>>,
    },

    #[error("integrated authentication failed: {0}")]
    IntegratedAuth(String),

    #[error("TLS failed: {detail}")]
    Tls { failure: TlsFailure, detail: String },

    #[error("{0}")]
    Server(Box<ServerDiagnostics>),

    #[error("{0}")]
    ReadOnly(ReadOnlyRefusal),

    #[error("cancelled")]
    Cancelled,

    #[error("timed out during {phase}")]
    Timeout {
        phase: TimeoutPhase,
        server_cancelled: bool,
    },

    #[error("the connection was lost while {during}")]
    ConnectionLost { during: LossPhase },

    /// Statement `statement_index` failed and the transaction was
    /// rolled back. Nothing was applied.
    #[error("rolled back at statement {statement_index}: {source}")]
    RolledBack {
        statement_index: usize,
        source: Box<DriverError>,
    },

    /// Statement `statement_index` was written to match exactly
    /// `expected` rows and matched `actual`, so the row it meant to
    /// change is not the row that is there. Nothing was applied.
    #[error("statement {statement_index} matched {actual} rows, not {expected}")]
    RowGuardFailed {
        statement_index: usize,
        expected: u64,
        actual: u64,
    },

    /// The engine cannot report how many rows a statement touched, so
    /// a write that has to know cannot run there.
    #[error("statement {statement_index} needs a row count this engine does not report")]
    GuardUnsupported { statement_index: usize },

    /// The commit was sent and the answer never arrived. The token,
    /// where the engine has one, is what asks the server later.
    #[error("the commit was sent and the outcome is unknown: {source}")]
    CommitOutcomeUnknown {
        token: Option<CommitToken>,
        source: Box<DriverError>,
    },

    /// `applied` statements are known to have landed, and the one at
    /// `statement_index` either failed or is unknown. The engine has no
    /// transaction to undo them.
    #[error("{applied} statements applied before statement {statement_index}: {source}")]
    PartiallyApplied {
        applied: usize,
        statement_index: usize,
        failed_outcome: StatementOutcome,
        source: Box<DriverError>,
    },

    #[error("no database file at {}", .path.display())]
    FileNotFound { path: PathBuf },

    #[error("no permission to open {}", .path.display())]
    FileAccessDenied { path: PathBuf },

    #[error("{} is not a database file", .path.display())]
    NotADatabase { path: PathBuf },

    #[error("the server has no room for another connection")]
    Busy,

    #[error("the editor session is already running a statement")]
    EditorSessionBusy,

    #[error(transparent)]
    Config(#[from] ConfigError),

    #[error("could not read column {column}: {detail}")]
    Decode { column: String, detail: String },

    #[error("the server sent something the driver could not read: {0}")]
    Protocol(String),

    #[error("this engine has no {feature}")]
    Unsupported { feature: &'static str },
}

impl DriverError {
    /// What kind of problem this is, which is what the app acts on.
    /// The message is for the user; the category decides which button
    /// to offer beside it.
    pub fn category(&self) -> ErrorCategory {
        match self {
            Self::Transport(error) => error.category(),
            Self::Auth { .. } | Self::IntegratedAuth(_) => ErrorCategory::Authentication,
            Self::Tls { .. } => ErrorCategory::Tls,
            Self::Server(_) => ErrorCategory::Server,
            Self::ReadOnly(_) => ErrorCategory::ReadOnly,
            Self::Cancelled => ErrorCategory::Interrupted,
            Self::Timeout { .. } => ErrorCategory::Timeout,
            Self::ConnectionLost { .. } => ErrorCategory::ConnectionLost,
            Self::RolledBack { .. }
            | Self::RowGuardFailed { .. }
            | Self::CommitOutcomeUnknown { .. }
            | Self::PartiallyApplied { .. } => ErrorCategory::WriteOutcome,
            Self::FileNotFound { .. } | Self::FileAccessDenied { .. } | Self::NotADatabase { .. } => {
                ErrorCategory::File
            }
            Self::Busy | Self::EditorSessionBusy => ErrorCategory::Busy,
            Self::Config(_) | Self::Unsupported { .. } => ErrorCategory::Configuration,
            Self::GuardUnsupported { .. } | Self::Decode { .. } | Self::Protocol(_) => ErrorCategory::Internal,
        }
    }

    /// A server error with nothing but its message, for an engine that
    /// numbers only some of what it reports.
    pub fn server(message: impl Into<String>) -> Self {
        Self::reported(ServerDiagnostics::new(None, message))
    }

    /// What the server said, in its own words.
    pub fn reported(diagnostics: ServerDiagnostics) -> Self {
        Self::Server(Box::new(diagnostics))
    }

    /// Credentials the server refused, with its explanation where it
    /// gave one.
    pub fn auth(diagnostics: Option<ServerDiagnostics>) -> Self {
        Self::Auth {
            diagnostics: diagnostics.map(Box::new),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server_diagnostics::ServerCode;

    fn assert_send_sync_error<E: std::error::Error + Send + Sync + 'static>() {}

    #[test]
    fn a_driver_error_crosses_threads() {
        assert_send_sync_error::<DriverError>();
    }

    #[test]
    fn a_write_that_rolled_back_is_not_a_server_error() {
        let rolled_back = DriverError::RolledBack {
            statement_index: 2,
            source: Box::new(DriverError::server("duplicate key")),
        };

        assert_eq!(rolled_back.category(), ErrorCategory::WriteOutcome);
        assert_eq!(
            DriverError::server("duplicate key").category(),
            ErrorCategory::Server,
            "the cause keeps its own category"
        );
    }

    #[test]
    fn a_guard_mismatch_reads_as_the_two_counts() {
        let failed = DriverError::RowGuardFailed {
            statement_index: 0,
            expected: 1,
            actual: 3,
        };

        assert_eq!(failed.to_string(), "statement 0 matched 3 rows, not 1");
        assert_eq!(failed.category(), ErrorCategory::WriteOutcome);
    }

    #[test]
    fn an_auth_failure_carries_the_servers_own_words() {
        let diagnostics = ServerDiagnostics::new(
            Some(ServerCode::SqlState("28P01".to_owned())),
            "password authentication failed",
        );
        let error = DriverError::auth(Some(diagnostics));

        assert_eq!(
            error.to_string(),
            "the server refused the credentials: password authentication failed (28P01)"
        );
        assert_eq!(error.category(), ErrorCategory::Authentication);
    }

    #[test]
    fn an_unreadable_column_is_ours_to_fix_not_the_servers() {
        let error = DriverError::Decode {
            column: "payload".to_owned(),
            detail: "unsupported type".to_owned(),
        };

        assert_eq!(error.category(), ErrorCategory::Internal);
    }
}
