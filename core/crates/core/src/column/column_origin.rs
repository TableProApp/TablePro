use crate::meta::TableRef;

// Set only for a direct column of a permanent base table, qualified so the window's connection names the same table.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ColumnOrigin {
    pub table: TableRef,
    pub column: String,
}

impl ColumnOrigin {
    pub fn new(table: TableRef, column: impl Into<String>) -> Self {
        Self {
            table,
            column: column.into(),
        }
    }
}
