use super::cell_accessibility::pending_state_text;
use crate::services::change_tracker::RowState;
use crate::ui::icons;

/// A row's pending change, as the grid shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowPendingState {
    Unchanged,
    Modified,
    Inserted,
    MarkedForDeletion,
    /// The row produced the statement a save just failed on.
    SaveFailed,
}

impl RowPendingState {
    pub fn new(state: RowState, save_failed: bool) -> Self {
        if save_failed {
            return Self::SaveFailed;
        }
        match state {
            RowState::Clean => Self::Unchanged,
            RowState::Modified => Self::Modified,
            RowState::InsertDraft => Self::Inserted,
            RowState::PendingDelete => Self::MarkedForDeletion,
        }
    }
}

/// The icon and its tooltip, so the state reads without its tint.
pub fn row_state_icon(state: RowPendingState) -> Option<(&'static str, String)> {
    let icon = match state {
        RowPendingState::Unchanged => return None,
        RowPendingState::Modified => icons::DOCUMENT_EDIT,
        RowPendingState::Inserted => icons::LIST_ADD,
        RowPendingState::MarkedForDeletion => icons::EDIT_DELETE,
        RowPendingState::SaveFailed => icons::DIALOG_ERROR,
    };
    Some((icon, pending_state_text(state)?))
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{RowPendingState, row_state_icon};
    use crate::services::change_tracker::RowState;

    const PENDING: [RowPendingState; 4] = [
        RowPendingState::Modified,
        RowPendingState::Inserted,
        RowPendingState::MarkedForDeletion,
        RowPendingState::SaveFailed,
    ];

    #[test]
    fn row_state_icons_are_distinct_and_described() {
        let shown: Vec<(&str, String)> = PENDING.into_iter().filter_map(row_state_icon).collect();

        assert_eq!(
            shown,
            [
                ("document-edit-symbolic", "Modified".to_owned()),
                ("list-add-symbolic", "New row".to_owned()),
                ("edit-delete-symbolic", "Marked for deletion".to_owned()),
                ("dialog-error-symbolic", "Not saved".to_owned()),
            ]
        );
        let icons: HashSet<&str> = shown.iter().map(|(icon, _)| *icon).collect();
        assert_eq!(icons.len(), PENDING.len());
        assert_eq!(row_state_icon(RowPendingState::Unchanged), None);
    }

    #[test]
    fn a_failed_save_outranks_the_rows_change() {
        assert_eq!(
            RowPendingState::new(RowState::Modified, true),
            RowPendingState::SaveFailed
        );
        assert_eq!(
            RowPendingState::new(RowState::InsertDraft, false),
            RowPendingState::Inserted
        );
        assert_eq!(
            RowPendingState::new(RowState::PendingDelete, false),
            RowPendingState::MarkedForDeletion
        );
        assert_eq!(RowPendingState::new(RowState::Clean, false), RowPendingState::Unchanged);
    }
}
