use tablepro_core::edit::ReadOnlyReason;

/// Why one cell of one row cannot be edited.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellLock {
    /// The column's values have no text form to type.
    Value(ReadOnlyReason),
    /// The row is named by this column, so changing it in place would
    /// lose the row it names.
    KeyColumn,
    Generated,
    AutoIncrement,
    UnkeyedRow,
    ResultRow,
    ReadOnlySession,
}
