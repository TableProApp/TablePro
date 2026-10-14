use thiserror::Error;

use crate::workspace::WorkspaceSaveError;

/// What was stored for a deleted connection and could not be removed.
/// None of it undoes the delete: nothing can reach it any more.
#[derive(Debug, Default)]
pub struct DeletionReport {
    pub purge_failures: Vec<PurgeFailure>,
}

impl DeletionReport {
    pub fn is_complete(&self) -> bool {
        self.purge_failures.is_empty()
    }

    /// The toast that tells the user what the delete of `name` left
    /// behind, or `None` when it left nothing.
    pub fn summary(&self, name: &str) -> Option<String> {
        let left = |wanted: fn(&PurgeFailure) -> bool| self.purge_failures.iter().any(wanted);
        let tabs = left(|failure| matches!(failure, PurgeFailure::Workspace(_)));
        let queries = left(|failure| matches!(failure, PurgeFailure::SavedQueries(_)));
        let history = left(|failure| matches!(failure, PurgeFailure::History(_)));
        let named = &[("name", name)];
        let text = match (tabs, queries, history) {
            (false, false, false) => return None,
            (true, false, false) => crate::i18n::gettext_f(
                "“{name}” was deleted, but some saved tabs or settings could not be removed",
                named,
            ),
            (true, ..) => crate::i18n::gettext_f(
                "“{name}” was deleted, but some of what was stored for it could not be removed",
                named,
            ),
            (false, true, true) => crate::i18n::gettext_f(
                "“{name}” was deleted, but its saved queries and query history could not be removed",
                named,
            ),
            (false, true, false) => crate::i18n::gettext_f(
                "“{name}” was deleted, but its saved queries could not be removed",
                named,
            ),
            (false, false, true) => crate::i18n::gettext_f(
                "“{name}” was deleted, but its query history could not be removed",
                named,
            ),
        };
        Some(text)
    }
}

#[derive(Debug, Error)]
pub enum PurgeFailure {
    #[error(transparent)]
    Workspace(WorkspaceSaveError),
    #[error("could not delete the saved queries: {0}")]
    SavedQueries(String),
    #[error("could not delete the query history: {0}")]
    History(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(failures: Vec<PurgeFailure>) -> DeletionReport {
        DeletionReport {
            purge_failures: failures,
        }
    }

    fn queries() -> PurgeFailure {
        PurgeFailure::SavedQueries("the query history did not open".to_owned())
    }

    #[test]
    fn a_complete_delete_has_nothing_to_say() {
        assert_eq!(report(Vec::new()).summary("Prod"), None);
    }

    #[test]
    fn the_summary_names_what_was_left_behind() {
        let tabs = report(vec![PurgeFailure::Workspace(WorkspaceSaveError::WriterStopped)]);
        let saved = report(vec![queries()]);
        let history = report(vec![PurgeFailure::History("locked".to_owned())]);
        let both = report(vec![queries(), PurgeFailure::History("locked".to_owned())]);

        assert_eq!(
            tabs.summary("Prod").as_deref(),
            Some("“Prod” was deleted, but some saved tabs or settings could not be removed")
        );
        assert_eq!(
            saved.summary("Prod").as_deref(),
            Some("“Prod” was deleted, but its saved queries could not be removed")
        );
        assert_eq!(
            history.summary("Prod").as_deref(),
            Some("“Prod” was deleted, but its query history could not be removed")
        );
        assert_eq!(
            both.summary("Prod").as_deref(),
            Some("“Prod” was deleted, but its saved queries and query history could not be removed")
        );
    }
}
