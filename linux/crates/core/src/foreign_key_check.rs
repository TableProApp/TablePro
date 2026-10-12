use crate::meta::TableRef;

/// One table whose foreign keys a suspended batch verifies.
///
/// `before` is the table's name when the batch starts and `after` its
/// name once the batch is done. They differ when a rebuild renames the
/// table, and a violation already there under the old name must not be
/// read as one the batch introduced under the new name. `before` is
/// `None` for a table the batch creates, which has nothing to compare
/// against.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ForeignKeyCheck {
    pub before: Option<TableRef>,
    pub after: TableRef,
}

impl ForeignKeyCheck {
    pub fn new(before: Option<TableRef>, after: TableRef) -> Self {
        Self { before, after }
    }

    /// A table that keeps its name through the batch.
    pub fn same_table(table: TableRef) -> Self {
        Self {
            before: Some(table.clone()),
            after: table,
        }
    }
}
