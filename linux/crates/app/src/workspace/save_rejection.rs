use tablepro_core::ddl::BuildDdlError;
use tablepro_core::dml::BuildSqlError;
use tablepro_session::OperationError;

use super::DirtyTab;
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
    /// Edits made before the table's columns changed are for these
    /// columns, which are gone or no longer take them.
    ColumnsChanged(Vec<String>),
    /// Edits made before the table's primary key changed name their
    /// rows by the old one.
    KeyChanged,
    /// The structure cannot be saved as it stands.
    Blocked(SaveBlocker),
    /// The structure cannot be written as SQL for the review to show.
    Unplannable(BuildDdlError),
    /// The user read the review of a structure save and kept it.
    ReviewDeclined,
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
            Self::ColumnsChanged(columns) => {
                let quoted: Vec<String> = columns.iter().map(|name| DirtyTab::quote(name)).collect();
                crate::i18n::gettext_f(
                    "The table changed after these edits were made, and the edits to {columns} no longer fit it. Nothing was saved. Discard the changes and make them again.",
                    &[("columns", &quoted.join(", "))],
                )
            }
            Self::KeyChanged => crate::i18n::gettext(
                "The table's primary key changed after these edits were made, so the rows they change can no longer be found. Nothing was saved. Discard the changes and make them again.",
            ),
            Self::Blocked(blocker) => crate::ui::error_text::save_blocker_text(blocker),
            Self::Unplannable(error) => crate::ui::error_text::build_error_text(error),
            Self::ReviewDeclined => crate::i18n::gettext("The changes were not applied."),
            Self::NoConnection => crate::i18n::gettext("No active connection."),
        }
    }

    /// A Save pressed again while the first runs needs no alert: the tab
    /// already shows the save running. Nor does a review the user just
    /// declined.
    pub fn needs_alert(&self) -> bool {
        !matches!(self, Self::AlreadySaving | Self::ReviewDeclined)
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
            SaveRejection::ColumnsChanged(vec!["nickname".to_owned()]),
            SaveRejection::KeyChanged,
        ];

        assert!(told.iter().all(SaveRejection::needs_alert));
        assert!(!SaveRejection::AlreadySaving.needs_alert());
        assert!(!SaveRejection::ReviewDeclined.needs_alert());
    }

    #[test]
    fn edits_the_columns_left_behind_name_their_columns() {
        let rejection = SaveRejection::ColumnsChanged(vec!["nickname".to_owned(), "age".to_owned()]);

        assert!(
            rejection.message().contains("“nickname”, “age”"),
            "{}",
            rejection.message()
        );
    }

    #[test]
    fn a_blocked_structure_says_what_to_fix() {
        let rejection = SaveRejection::Blocked(SaveBlocker::Draft(DraftProblem::NoColumns));

        assert_eq!(rejection.message(), "At least one column is required.");
    }
}
