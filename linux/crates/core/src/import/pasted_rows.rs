use crate::edit::CellInput;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct PastedRows {
    pub rows: Vec<Vec<CellInput>>,
    /// Values the paste found no column to put in: past the last
    /// column, under a header no column has, or in a column the server
    /// fills or the grid cannot edit.
    pub skipped: usize,
}
