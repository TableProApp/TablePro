use super::row_state_icon::RowPendingState;
use crate::services::change_tracker::CellState;

/// What a screen reader adds to a cell's value. A new row's cells say
/// nothing of their own: the row says it is new. A NULL is named, since
/// it reads as the text "NULL" would.
pub fn cell_description(state: CellState, null: bool) -> Option<String> {
    let text = match (state, null) {
        (CellState::Modified, true) => crate::i18n::gettext("Modified, NULL value"),
        (CellState::Modified, false) => crate::i18n::gettext("Modified"),
        (_, true) => crate::i18n::gettext("NULL value"),
        (_, false) => return None,
    };
    Some(text)
}

/// What a screen reader adds to a row. An edited row says nothing of its
/// own: its edited cells do.
pub fn row_description(state: RowPendingState) -> Option<String> {
    match state {
        RowPendingState::Modified => None,
        other => pending_state_text(other),
    }
}

pub(super) fn pending_state_text(state: RowPendingState) -> Option<String> {
    let text = match state {
        RowPendingState::Unchanged => return None,
        RowPendingState::Modified => crate::i18n::gettext("Modified"),
        RowPendingState::Inserted => crate::i18n::gettext("New row"),
        RowPendingState::MarkedForDeletion => crate::i18n::gettext("Marked for deletion"),
        RowPendingState::SaveFailed => crate::i18n::gettext("Not saved"),
    };
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::{cell_description, row_description};
    use crate::services::change_tracker::CellState;
    use crate::ui::grid::row_state_icon::RowPendingState;

    #[test]
    fn cell_and_row_descriptions() {
        assert_eq!(
            cell_description(CellState::Modified, false).as_deref(),
            Some("Modified")
        );
        assert_eq!(cell_description(CellState::Clean, false), None);
        assert_eq!(cell_description(CellState::InsertDraft, false), None);
        assert_eq!(row_description(RowPendingState::Inserted).as_deref(), Some("New row"));
        assert_eq!(
            row_description(RowPendingState::MarkedForDeletion).as_deref(),
            Some("Marked for deletion")
        );
        assert_eq!(
            row_description(RowPendingState::SaveFailed).as_deref(),
            Some("Not saved")
        );
        assert_eq!(row_description(RowPendingState::Unchanged), None);
        assert_eq!(row_description(RowPendingState::Modified), None);
    }

    #[test]
    fn cell_description_marks_null_and_modified() {
        assert_eq!(
            cell_description(CellState::Modified, true).as_deref(),
            Some("Modified, NULL value")
        );
        assert_eq!(cell_description(CellState::Clean, true).as_deref(), Some("NULL value"));
        assert_eq!(
            cell_description(CellState::InsertDraft, true).as_deref(),
            Some("NULL value")
        );
        assert_eq!(cell_description(CellState::Clean, false), None);
    }
}
