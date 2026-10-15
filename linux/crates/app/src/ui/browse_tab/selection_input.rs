/// What changes the rows selected in the grid.
#[derive(Debug)]
pub(crate) enum SelectionInput {
    /// Esc. A single selected row stays selected: clearing it would
    /// strand the keyboard focus indicator.
    ClearSelection,
}
