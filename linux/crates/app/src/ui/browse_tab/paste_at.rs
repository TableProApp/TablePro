use crate::ui::grid::RowObject;

/// The cell a paste starts at: one value goes into it, and rows fill
/// the table's columns from its column on.
#[derive(Debug, Clone)]
pub(crate) struct PasteAt {
    pub(crate) row: RowObject,
    pub(crate) column: usize,
}
