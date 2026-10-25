/// What Copy takes (inventory D3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopyScope {
    /// The focused cell's value, by column index.
    Value(usize),
    Rows,
}

/// One selected row, or none with a focused cell, copies that cell's
/// value; several rows copy the rows.
pub fn copy_scope(selected_rows: usize, focused_column: Option<usize>) -> CopyScope {
    match (selected_rows, focused_column) {
        (0 | 1, Some(column)) => CopyScope::Value(column),
        _ => CopyScope::Rows,
    }
}

#[cfg(test)]
mod tests {
    use super::{CopyScope, copy_scope};

    #[test]
    fn one_row_copies_the_focused_value_and_several_copy_rows() {
        assert_eq!(copy_scope(1, Some(2)), CopyScope::Value(2));
        assert_eq!(
            copy_scope(0, Some(0)),
            CopyScope::Value(0),
            "a focused cell with no selection"
        );
        assert_eq!(copy_scope(2, Some(2)), CopyScope::Rows);
        assert_eq!(copy_scope(500, None), CopyScope::Rows);
        assert_eq!(copy_scope(1, None), CopyScope::Rows, "a row with no focused cell");
    }
}
