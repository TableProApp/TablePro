use tablepro_core::DriverError;
use tablepro_core::browse::BrowseSqlError;
use tablepro_core::dml::BuildSqlError;
use tablepro_core::statement::SqlBuildError;
use tablepro_session::OperationError;

/// Why a save left the database as it was.
#[derive(Debug, Clone, PartialEq)]
pub enum RollbackCause {
    /// The server refused it, or the driver undid it.
    Driver(DriverError),
    /// It could not be written as SQL, so nothing was sent.
    Sql(SqlBuildError),
    Build(BuildSqlError),
    Browse(BrowseSqlError),
    /// The commit's answer was lost, and the server said afterwards that
    /// it never landed.
    NotApplied,
}

impl RollbackCause {
    /// What to tell the user.
    pub fn message(&self) -> String {
        match self {
            Self::Driver(error) => crate::ui::error_text::driver_message(error),
            Self::Sql(error) => crate::ui::error_text::operation_error_message(&OperationError::Sql(error.clone())),
            Self::Build(error) => crate::ui::error_text::operation_error_message(&OperationError::Build(error.clone())),
            Self::Browse(error) => {
                crate::ui::error_text::operation_error_message(&OperationError::Browse(error.clone()))
            }
            Self::NotApplied => crate::i18n::gettext(
                "The connection was lost while saving, and the database says the changes were not saved.",
            ),
        }
    }

    /// A guard found what the save was built from changed after it was
    /// read: the row, for a row save, or the table, for a structure save.
    pub fn found_changes(&self) -> bool {
        matches!(self, Self::Driver(DriverError::RowGuardFailed { .. }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_failed_guard_found_changes() {
        let guard = RollbackCause::Driver(DriverError::RowGuardFailed {
            statement_index: 0,
            expected: 0,
            actual: 2,
        });
        let refused = RollbackCause::Driver(DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(DriverError::server("UNIQUE constraint failed")),
        });

        assert!(guard.found_changes());
        assert!(!refused.found_changes());
        assert!(!RollbackCause::NotApplied.found_changes());
    }
}
