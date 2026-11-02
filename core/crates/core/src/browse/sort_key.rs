/// One column the user sorted the grid by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SortKey {
    /// Position in the table's columns.
    pub column: usize,
    pub ascending: bool,
}
