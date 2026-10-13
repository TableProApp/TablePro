use tablepro_core::dml::BuildSqlError;
use tablepro_session::OperationError;

use crate::services::pending_structure::SaveBlocker;

/// Why a save did not start. Nothing was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveRejection {
    /// The last save's outcome is unknown, and saving again could apply
    /// the same changes twice.
    OutcomeUnknown,
    AlreadySaving,
    ReadOnly,
    /// The tab has not read the table's columns, which a row save is
    /// planned against.
    ColumnsNotRead,
    /// The row changes cannot be written as SQL.
    Build(BuildSqlError),
    /// The structure cannot be saved as it stands.
    Blocked(SaveBlocker),
    NoConnection,
}

impl SaveRejection {
    /// What to tell the user.
    pub fn message(&self) -> String {
        match self {
            Self::OutcomeUnknown => crate::i18n::gettext(
                "The last save may already be in the database. Discard these changes to see what the table holds now.",
            ),
            Self::AlreadySaving => crate::i18n::gettext("These changes are already being saved."),
            Self::ReadOnly => crate::i18n::gettext("This connection is read-only."),
            Self::ColumnsNotRead => {
                crate::i18n::gettext("The table's columns have not been read yet. Try again in a moment.")
            }
            Self::Build(error) => crate::ui::error_text::operation_error_message(&OperationError::Build(error.clone())),
            Self::Blocked(blocker) => crate::ui::error_text::save_blocker_text(blocker),
            Self::NoConnection => crate::i18n::gettext("No active connection."),
        }
    }

    /// A Save pressed again while the first runs needs no alert: the tab
    /// already shows the save running.
    pub fn needs_alert(&self) -> bool {
        !matches!(self, Self::AlreadySaving)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::DraftProblem;

    use super::*;

    #[test]
    fn only_a_save_already_running_goes_untold() {
        let told = [
            SaveRejection::OutcomeUnknown,
            SaveRejection::ReadOnly,
            SaveRejection::ColumnsNotRead,
            SaveRejection::Blocked(SaveBlocker::Draft(DraftProblem::NoColumns)),
            SaveRejection::NoConnection,
        ];

        assert!(told.iter().all(SaveRejection::needs_alert));
        assert!(!SaveRejection::AlreadySaving.needs_alert());
    }

    #[test]
    fn a_blocked_structure_says_what_to_fix() {
        let rejection = SaveRejection::Blocked(SaveBlocker::Draft(DraftProblem::NoColumns));

        assert_eq!(rejection.message(), "At least one column is required.");
    }
}
