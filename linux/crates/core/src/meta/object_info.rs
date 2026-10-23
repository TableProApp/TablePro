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
    /// A key of a key-value engine, with the type of value it holds. It
    /// opens in a key tab, not the grid's paging.
    Key(KeyKind),
}

/// The type of value a key holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyKind {
    String,
    Hash,
    List,
    Set,
    SortedSet,
    Stream,
    /// A module's type, such as a JSON document, which the key tab names
    /// but does not read.
    Other,
}

impl ObjectKind {
    /// Whether the grid can page through it.
    pub fn is_browsable(self) -> bool {
        matches!(
            self,
            Self::Table | Self::PartitionedTable | Self::View | Self::MaterializedView | Self::ForeignTable
        )
    }

    pub fn is_key(self) -> bool {
        matches!(self, Self::Key(_))
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
    fn a_key_is_neither_browsable_nor_editable() {
        let key = ObjectKind::Key(KeyKind::Hash);

        assert!(key.is_key());
        assert!(!key.is_browsable());
        assert!(!key.is_structure_editable());
        assert!(!ObjectKind::Table.is_key());
    }

    #[test]
    fn a_partitioned_table_behaves_like_a_table() {
        assert!(ObjectKind::PartitionedTable.is_browsable());
        assert!(ObjectKind::PartitionedTable.is_structure_editable());
    }
}
