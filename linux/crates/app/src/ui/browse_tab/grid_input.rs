use crate::ui::data_grid::GridRequest;

/// What the grid tells the tab, and what the tab's own buttons hand the
/// grid: Export, Undo and Redo.
#[derive(Debug)]
pub(crate) enum GridInput {
    Request(GridRequest),
    SelectionChanged,
    /// An inline or detail pane edit opened or closed.
    EditingChanged,
    /// The Export button: the page as the grid shows it.
    Export,
    Undo,
    Redo,
}
