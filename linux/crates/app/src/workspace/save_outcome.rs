use tablepro_core::{DriverError, ErrorCategory, WriteReport};
use tablepro_session::OperationError;

use super::{RollbackCause, UnknownCause};

/// What a save left in the database, which decides what its tracker
/// does next.
#[derive(Debug, Clone, PartialEq)]
pub enum SaveOutcome {
    /// Every statement landed. `rows` is the total the server reported,
    /// when every statement reported one.
    Committed { rows: Option<u64> },
    /// Nothing landed.
    RolledBack(RollbackCause),
    /// It may have landed, and only the server can say.
    Unknown(UnknownCause),
}

impl SaveOutcome {
    /// Once a statement is sent, a driver reports every failure as
    /// rolled back, partly applied or of unknown outcome. A bare error
    /// in a category that can strike mid-commit cannot be trusted to
    /// mean nothing landed; any other bare error means nothing was sent.
    pub fn classify(result: Result<WriteReport, OperationError>) -> Self {
        match result {
            Ok(report) => Self::Committed {
                rows: report.total_rows(),
            },
            Err(OperationError::Driver(error)) => Self::from_driver(error),
            Err(OperationError::Sql(error)) => Self::RolledBack(RollbackCause::Sql(error)),
            Err(OperationError::Build(error)) => Self::RolledBack(RollbackCause::Build(error)),
            Err(OperationError::Browse(error)) => Self::RolledBack(RollbackCause::Browse(error)),
            Err(OperationError::Cancelled) => Self::Unknown(UnknownCause::Interrupted),
            Err(OperationError::Panicked(_)) => Self::Unknown(UnknownCause::Panicked),
            Err(OperationError::Closed) => Self::Unknown(UnknownCause::Closed),
        }
    }

    fn from_driver(error: DriverError) -> Self {
        match error {
            DriverError::RolledBack { .. } | DriverError::RowGuardFailed { .. } | DriverError::ReadOnly(_) => {
                Self::RolledBack(RollbackCause::Driver(error))
            }
            DriverError::CommitOutcomeUnknown { token, .. } => Self::Unknown(UnknownCause::CommitAckLost { token }),
            DriverError::PartiallyApplied { .. } => Self::Unknown(UnknownCause::PartiallyApplied),
            other => match other.category() {
                ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost => {
                    Self::Unknown(UnknownCause::Interrupted)
                }
                _ => Self::RolledBack(RollbackCause::Driver(other)),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::dml::BuildSqlError;
    use tablepro_core::statement::SqlBuildError;
    use tablepro_core::{CommitToken, LossPhase, ReadOnlyRefusal, StatementOutcome, TimeoutPhase, TransportError};
    use tablepro_session::runtime::TaskPanic;

    use super::*;

    fn driver(error: DriverError) -> SaveOutcome {
        SaveOutcome::classify(Err(OperationError::Driver(error)))
    }

    fn rolled_back(outcome: &SaveOutcome) -> bool {
        matches!(outcome, SaveOutcome::RolledBack(_))
    }

    #[test]
    fn classify_maps_every_contract_case() {
        let token = CommitToken::PostgresXid {
            xid: 7,
            legacy_txid: false,
        };

        assert_eq!(
            SaveOutcome::classify(Ok(WriteReport::new(vec![Some(2), Some(1)]))),
            SaveOutcome::Committed { rows: Some(3) }
        );
        for error in [
            DriverError::RolledBack {
                statement_index: 0,
                source: Box::new(DriverError::server("duplicate key")),
            },
            DriverError::RolledBack {
                statement_index: 1,
                source: Box::new(DriverError::Cancelled),
            },
            DriverError::RolledBack {
                statement_index: 1,
                source: Box::new(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled: true,
                }),
            },
            DriverError::RowGuardFailed {
                statement_index: 0,
                expected: 1,
                actual: 0,
            },
            DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard),
        ] {
            assert!(rolled_back(&driver(error.clone())), "{error:?}");
        }
        assert_eq!(
            driver(DriverError::CommitOutcomeUnknown {
                token: Some(token.clone()),
                source: Box::new(DriverError::ConnectionLost {
                    during: LossPhase::Commit
                }),
            }),
            SaveOutcome::Unknown(UnknownCause::CommitAckLost { token: Some(token) })
        );
        assert_eq!(
            driver(DriverError::PartiallyApplied {
                applied: 1,
                statement_index: 1,
                failed_outcome: StatementOutcome::Unknown,
                source: Box::new(DriverError::Cancelled),
            }),
            SaveOutcome::Unknown(UnknownCause::PartiallyApplied)
        );
        for interrupted in [
            DriverError::Cancelled,
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: false,
            },
            DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
        ] {
            assert_eq!(
                driver(interrupted.clone()),
                SaveOutcome::Unknown(UnknownCause::Interrupted),
                "{interrupted:?}"
            );
        }
        assert_eq!(
            SaveOutcome::classify(Err(OperationError::Cancelled)),
            SaveOutcome::Unknown(UnknownCause::Interrupted)
        );
        for refused in [
            DriverError::Busy,
            DriverError::server("syntax error"),
            DriverError::auth(None),
            DriverError::Transport(TransportError::NameResolution {
                host: "db".to_owned(),
                detail: "no such host".to_owned(),
            }),
            DriverError::Protocol("garbled".to_owned()),
        ] {
            assert!(rolled_back(&driver(refused.clone())), "{refused:?}");
        }
        assert_eq!(
            SaveOutcome::classify(Err(OperationError::Sql(SqlBuildError::Ddl("no".to_owned())))),
            SaveOutcome::RolledBack(RollbackCause::Sql(SqlBuildError::Ddl("no".to_owned())))
        );
        assert_eq!(
            SaveOutcome::classify(Err(OperationError::Build(BuildSqlError::NoRowIdentity))),
            SaveOutcome::RolledBack(RollbackCause::Build(BuildSqlError::NoRowIdentity))
        );
        assert_eq!(
            SaveOutcome::classify(Err(OperationError::Panicked(TaskPanic::from_payload(Box::new("boom"))))),
            SaveOutcome::Unknown(UnknownCause::Panicked)
        );
        assert_eq!(
            SaveOutcome::classify(Err(OperationError::Closed)),
            SaveOutcome::Unknown(UnknownCause::Closed)
        );
    }
}
