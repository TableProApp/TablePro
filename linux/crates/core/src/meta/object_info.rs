/// A database object the sidebar can show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectInfo {
    pub schema: Option<String>,
    pub name: String,
    pub kind: ObjectKind,
}

/// What kind of object it is.
///
/// Non-exhaustive: a driver added later can report a kind this build
/// does not know, and a match on it must keep compiling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ObjectKind {
    Table,
    PartitionedTable,
    View,
    MaterializedView,
    ForeignTable,
    Sequence,
    Function,
    Procedure,
    Dictionary,
}

impl ObjectKind {
    /// Whether the grid can page through it.
    pub fn is_browsable(self) -> bool {
        matches!(
            self,
            Self::Table | Self::PartitionedTable | Self::View | Self::MaterializedView | Self::ForeignTable
        )
    }

    /// Whether the structure tab can change its columns. A view's
    /// shape comes from its query, not from a column list.
    pub fn is_structure_editable(self) -> bool {
        matches!(self, Self::Table | Self::PartitionedTable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_view_is_browsable_but_not_editable() {
        assert!(ObjectKind::View.is_browsable());
        assert!(!ObjectKind::View.is_structure_editable());
    }

    #[test]
    fn a_routine_is_neither() {
        for kind in [ObjectKind::Function, ObjectKind::Procedure, ObjectKind::Sequence] {
            assert!(!kind.is_browsable(), "{kind:?}");
            assert!(!kind.is_structure_editable(), "{kind:?}");
        }
    }

    #[test]
    fn a_partitioned_table_behaves_like_a_table() {
        assert!(ObjectKind::PartitionedTable.is_browsable());
        assert!(ObjectKind::PartitionedTable.is_structure_editable());
    }
}
