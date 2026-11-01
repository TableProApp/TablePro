/// A database object the sidebar can show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectInfo {
    pub schema: Option<String>,
    pub name: String,
    pub kind: ObjectKind,
    /// The table a trigger fires on. `None` for every other kind.
    pub table: Option<String>,
}

impl ObjectInfo {
    /// An object that belongs to no table.
    pub fn new(schema: Option<String>, name: impl Into<String>, kind: ObjectKind) -> Self {
        Self {
            schema,
            name: name.into(),
            kind,
            table: None,
        }
    }

    /// A trigger on `table`, in the table's schema.
    pub fn trigger(schema: Option<String>, name: impl Into<String>, table: impl Into<String>) -> Self {
        Self {
            schema,
            name: name.into(),
            kind: ObjectKind::Trigger,
            table: Some(table.into()),
        }
    }
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
    Trigger,
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

    /// Whether its definition is SQL to read rather than rows to page:
    /// a routine, a sequence or a trigger.
    pub fn has_definition(self) -> bool {
        matches!(self, Self::Function | Self::Procedure | Self::Sequence | Self::Trigger)
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
        for kind in [
            ObjectKind::Function,
            ObjectKind::Procedure,
            ObjectKind::Sequence,
            ObjectKind::Trigger,
        ] {
            assert!(!kind.is_browsable(), "{kind:?}");
            assert!(!kind.is_structure_editable(), "{kind:?}");
            assert!(kind.has_definition(), "{kind:?}");
        }
        assert!(!ObjectKind::Table.has_definition());
        assert!(!ObjectKind::View.has_definition());
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

    #[test]
    fn only_a_trigger_names_its_table() {
        let trigger = ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders");
        let function = ObjectInfo::new(Some("public".to_owned()), "audit", ObjectKind::Function);

        assert_eq!(trigger.kind, ObjectKind::Trigger);
        assert_eq!(trigger.table.as_deref(), Some("orders"));
        assert_eq!(function.table, None);
    }
}
