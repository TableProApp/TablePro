/// The ClickHouse table keys a column is part of.
///
/// A column in the sorting or partition key cannot be renamed, retyped
/// or dropped without rebuilding the table, so the structure tab has to
/// know before it offers any of that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ColumnKeyRoles {
    pub sorting_key: bool,
    pub partition_key: bool,
}
