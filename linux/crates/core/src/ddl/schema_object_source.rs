/// What kind of object a dependent is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SchemaObjectKind {
    Index,
    Trigger,
    View,
}

/// An object that has to be recreated when its table is rebuilt.
///
/// SQLite rebuilds a table to change it, and dropping the old table
/// drops its indexes and triggers with it, so the rebuild replays each
/// one from the SQL the schema stored.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SchemaObjectSource {
    pub kind: SchemaObjectKind,
    pub name: String,
    /// The table the object belongs to, which for a view or a trigger on
    /// another table is not the one being rebuilt.
    pub table: String,
    pub sql: String,
}
