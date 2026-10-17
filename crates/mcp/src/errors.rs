use std::fmt;

use serde::Serialize;
use tablepro_core::DriverError;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OperationOutcome {
    NotStarted,
    ConfirmedFailure,
    Unknown,
    Committed,
    RolledBack,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransactionOutcome {
    NotApplicable,
    NotStarted,
    RolledBack,
    Unknown,
    Committed,
}

#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct McpToolError {
    pub code: &'static str,
    pub operation_outcome: OperationOutcome,
    pub transaction_outcome: TransactionOutcome,
    pub message: &'static str,
    #[serde(skip)]
    legacy_diagnostic: String,
}

impl fmt::Debug for McpToolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("McpToolError")
            .field("code", &self.code)
            .field("operation_outcome", &self.operation_outcome)
            .field("transaction_outcome", &self.transaction_outcome)
            .field("message", &self.message)
            .finish()
    }
}

impl McpToolError {
    pub(crate) fn structured_content(&self) -> serde_json::Value {
        serde_json::json!({
            "code": self.code,
            "operation_outcome": self.operation_outcome,
            "transaction_outcome": self.transaction_outcome,
            "message": self.message,
        })
    }

    pub(crate) fn request_failed() -> Self {
        Self {
            code: "request_failed",
            operation_outcome: OperationOutcome::NotStarted,
            transaction_outcome: TransactionOutcome::NotApplicable,
            message: "The tool call could not be completed.",
            legacy_diagnostic: "The tool call could not be completed.".into(),
        }
    }

    pub(crate) fn from_write_error(error: &DriverError) -> Self {
        let (code, operation_outcome, transaction_outcome, message) = match error {
            DriverError::OperationOutcomeUnknown { .. }
            | DriverError::ConnectionRefused
            | DriverError::AuthFailed
            | DriverError::Disconnected
            | DriverError::Internal(_)
            | DriverError::IntegratedAuth(_)
            | DriverError::Tls(_) => (
                "operation_outcome_unknown",
                OperationOutcome::Unknown,
                TransactionOutcome::NotApplicable,
                "The write may have been applied; check database state before retrying.",
            ),
            DriverError::PartiallyApplied { source, .. } | DriverError::Transaction { source, .. }
                if tablepro_policy::is_ambiguous_post_dispatch(source) =>
            {
                (
                    "operation_outcome_unknown",
                    OperationOutcome::Unknown,
                    TransactionOutcome::Unknown,
                    "The write may have been applied; check database state before retrying.",
                )
            }
            DriverError::TransactionRollbackFailed { .. }
            | DriverError::PartiallyApplied { .. }
            | DriverError::Transaction { .. } => batch_failure_envelope(error),
            DriverError::Cancelled => (
                "operation_cancelled",
                OperationOutcome::ConfirmedFailure,
                TransactionOutcome::NotApplicable,
                "The database confirmed that the operation was cancelled.",
            ),
            DriverError::TimedOut => (
                "operation_timed_out",
                OperationOutcome::ConfirmedFailure,
                TransactionOutcome::NotApplicable,
                "The database confirmed that the operation timed out.",
            ),
            DriverError::PolicyDenied(_) | DriverError::ReadOnly => (
                "write_refused",
                OperationOutcome::NotStarted,
                TransactionOutcome::NotApplicable,
                "The write was refused before database execution.",
            ),
            DriverError::Query { .. } | DriverError::Unsupported(_) | DriverError::ConcurrentModification => (
                "write_failed",
                OperationOutcome::ConfirmedFailure,
                TransactionOutcome::NotApplicable,
                "The database rejected the write.",
            ),
        };
        Self {
            code,
            operation_outcome,
            transaction_outcome,
            message,
            legacy_diagnostic: bounded_diagnostic(&error.to_string()),
        }
    }

    pub(crate) fn transaction_rollback_failed(error: &DriverError) -> Self {
        Self {
            code: "transaction_rollback_failed",
            operation_outcome: OperationOutcome::Unknown,
            transaction_outcome: TransactionOutcome::Unknown,
            message: "The transaction rollback could not be confirmed.",
            legacy_diagnostic: bounded_diagnostic(&format!("preview rollback could not be confirmed: {error}")),
        }
    }

    pub(crate) fn legacy_diagnostic(&self) -> String {
        self.legacy_diagnostic.clone()
    }
}

fn bounded_diagnostic(value: &str) -> String {
    value
        .chars()
        .take(512)
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect()
}

impl From<String> for McpToolError {
    fn from(value: String) -> Self {
        Self {
            legacy_diagnostic: bounded_diagnostic(&value),
            ..Self::request_failed()
        }
    }
}

impl From<&str> for McpToolError {
    fn from(value: &str) -> Self {
        Self::from(value.to_string())
    }
}

fn batch_failure_envelope(error: &DriverError) -> (&'static str, OperationOutcome, TransactionOutcome, &'static str) {
    match error {
        DriverError::TransactionRollbackFailed { .. } => (
            "transaction_rollback_failed",
            OperationOutcome::Unknown,
            TransactionOutcome::Unknown,
            "The transaction failed and rollback could not be confirmed.",
        ),
        DriverError::PartiallyApplied { .. } => (
            "batch_partially_applied",
            OperationOutcome::ConfirmedFailure,
            TransactionOutcome::NotApplicable,
            "The batch stopped at a failing statement; the statements before it were applied and not rolled back.",
        ),
        DriverError::Transaction { .. } => (
            "transaction_failed",
            OperationOutcome::ConfirmedFailure,
            TransactionOutcome::RolledBack,
            "The transaction failed and rollback was confirmed.",
        ),
        _ => (
            "operation_outcome_unknown",
            OperationOutcome::Unknown,
            TransactionOutcome::Unknown,
            "The write may have been applied; check database state before retrying.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tablepro_core::DriverError;

    use super::{McpToolError, OperationOutcome, TransactionOutcome};

    #[test]
    fn unknown_write_outcome_has_a_stable_safe_envelope() {
        let error = McpToolError::from_write_error(&DriverError::OperationOutcomeUnknown {
            source: Box::new(DriverError::query("secret_value")),
        });

        assert_eq!(
            serde_json::to_value(&error).unwrap(),
            json!({
                "code": "operation_outcome_unknown",
                "operation_outcome": "unknown",
                "transaction_outcome": "not_applicable",
                "message": "The write may have been applied; check database state before retrying."
            })
        );
        assert!(!error.message.contains("secret_value"));
    }

    #[test]
    fn rollback_failure_is_not_reported_as_a_clean_transaction() {
        let error = McpToolError::from_write_error(&DriverError::TransactionRollbackFailed {
            statement_index: 0,
            source: Box::new(DriverError::query("statement detail")),
            rollback_error: Box::new(DriverError::Disconnected),
        });

        assert_eq!(error.code, "transaction_rollback_failed");
        assert_eq!(error.operation_outcome, OperationOutcome::Unknown);
        assert_eq!(error.transaction_outcome, TransactionOutcome::Unknown);
    }

    #[test]
    fn a_partially_applied_batch_is_not_reported_as_rolled_back() {
        let error = McpToolError::from_write_error(&DriverError::non_atomic_batch_failure(
            2,
            DriverError::query("statement detail"),
        ));

        assert_eq!(error.code, "batch_partially_applied");
        assert_ne!(error.transaction_outcome, TransactionOutcome::RolledBack);
    }

    #[test]
    fn a_batch_lost_mid_statement_is_never_reported_as_a_confirmed_rollback() {
        for error in [
            DriverError::non_atomic_batch_failure(0, DriverError::Disconnected),
            DriverError::non_atomic_batch_failure(2, DriverError::Disconnected),
        ] {
            let envelope = McpToolError::from_write_error(&error);
            assert_eq!(envelope.code, "operation_outcome_unknown", "{error:?}");
            assert_eq!(envelope.operation_outcome, OperationOutcome::Unknown);
        }
    }

    #[test]
    fn confirmed_cancellation_is_distinct_from_an_unknown_interruption() {
        let error = McpToolError::from_write_error(&DriverError::Cancelled);

        assert_eq!(error.code, "operation_cancelled");
        assert_eq!(error.operation_outcome, OperationOutcome::ConfirmedFailure);
        assert_eq!(error.transaction_outcome, TransactionOutcome::NotApplicable);
    }

    #[test]
    fn policy_refusal_says_the_write_never_started() {
        let error = McpToolError::from_write_error(&DriverError::PolicyDenied("detail".into()));

        assert_eq!(error.code, "write_refused");
        assert_eq!(error.operation_outcome, OperationOutcome::NotStarted);
    }
}
