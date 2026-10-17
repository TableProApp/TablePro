use super::*;
use crate::audit::{AuditErrorCategory, AuditTerminalStatus, AuditTransactionOutcome};

#[test]
fn rollback_failure_is_audited_as_an_unknown_transaction_outcome() {
    let error = DriverError::TransactionRollbackFailed {
        statement_index: 1,
        source: Box::new(DriverError::Query {
            message: "statement failed".into(),
            sqlstate: None,
            position: None,
        }),
        rollback_error: Box::new(DriverError::Disconnected),
    };

    assert_eq!(
        super::super::transaction_error_outcome(&error),
        (AuditTerminalStatus::Unknown, AuditTransactionOutcome::Unknown, true)
    );
    assert_eq!(super::super::error_category(&error), AuditErrorCategory::Unknown);
}

#[test]
fn confirmed_transaction_rollback_is_not_audited_as_an_unknown_outcome() {
    let error = DriverError::Transaction {
        statement_index: 1,
        source: Box::new(DriverError::ConcurrentModification),
    };

    assert_eq!(
        super::super::transaction_error_outcome(&error),
        (AuditTerminalStatus::Failed, AuditTransactionOutcome::RolledBack, false)
    );
    assert_eq!(super::super::error_category(&error), AuditErrorCategory::Transaction);
}

#[test]
fn a_partially_applied_batch_is_not_audited_as_rolled_back() {
    let error = DriverError::non_atomic_batch_failure(2, DriverError::query("statement failed"));

    assert_eq!(
        super::super::transaction_error_outcome(&error),
        (AuditTerminalStatus::Failed, AuditTransactionOutcome::Failed, false)
    );
    let first = DriverError::non_atomic_batch_failure(0, DriverError::query("statement failed"));
    assert_eq!(
        super::super::transaction_error_outcome(&first),
        (AuditTerminalStatus::Failed, AuditTransactionOutcome::RolledBack, false)
    );
    let lost = DriverError::non_atomic_batch_failure(1, DriverError::Disconnected);
    assert_eq!(
        super::super::transaction_error_outcome(&lost),
        (AuditTerminalStatus::Unknown, AuditTransactionOutcome::Unknown, true)
    );
}

#[test]
fn a_first_statement_lost_mid_flight_is_never_reported_as_rolled_back() {
    for error in [
        DriverError::non_atomic_batch_failure(0, DriverError::Disconnected),
        DriverError::Transaction {
            statement_index: 0,
            source: Box::new(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::Cancelled),
            }),
        },
    ] {
        assert_eq!(
            super::super::transaction_error_outcome(&error),
            (AuditTerminalStatus::Unknown, AuditTransactionOutcome::Unknown, true),
            "{error:?}"
        );
    }
}

#[test]
fn a_partially_applied_import_batch_is_not_audited_as_rolled_back() {
    let error = DriverError::non_atomic_batch_failure(3, DriverError::query("statement failed"));
    let (_, outcome, _) = super::super::bulk::bulk_terminal(crate::guard::BulkInsertEnd::Failed(&error), 0);
    assert_eq!(outcome, AuditTransactionOutcome::Failed);
}

#[test]
fn read_only_transaction_error_is_a_known_failure_without_disabling_writes() {
    assert_eq!(
        super::super::interactive_transaction_error_outcome(&DriverError::ReadOnly),
        (AuditTerminalStatus::Failed, AuditTransactionOutcome::Failed, false)
    );
}
