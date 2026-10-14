use crate::services::change_tracker::{CellState, RowState};

/// What a screen reader adds to a cell's value. A new row's cells say
/// nothing of their own: the row says it is new.
pub fn cell_description(state: CellState) -> Option<String> {
    match state {
        CellState::Modified => Some(crate::i18n::gettext("Modified")),
        CellState::Clean | CellState::InsertDraft => None,
    }
}

/// What a screen reader adds to a row. An edited row says nothing of its
/// own: its edited cells do.
pub fn row_description(state: RowState) -> Option<String> {
    match state {
        RowState::InsertDraft => Some(crate::i18n::gettext("New row")),
        RowState::PendingDelete => Some(crate::i18n::gettext("Marked for deletion")),
        RowState::Clean | RowState::Modified => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{cell_description, row_description};
    use crate::services::change_tracker::{CellState, RowState};

    #[test]
    fn cell_and_row_descriptions() {
        assert_eq!(cell_description(CellState::Modified).as_deref(), Some("Modified"));
        assert_eq!(cell_description(CellState::Clean), None);
        assert_eq!(cell_description(CellState::InsertDraft), None);
        assert_eq!(row_description(RowState::InsertDraft).as_deref(), Some("New row"));
        assert_eq!(
            row_description(RowState::PendingDelete).as_deref(),
            Some("Marked for deletion")
        );
        assert_eq!(row_description(RowState::Clean), None);
        assert_eq!(row_description(RowState::Modified), None);
    }
}
