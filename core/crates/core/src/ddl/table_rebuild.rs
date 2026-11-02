use super::SchemaObjectKind;

/// A plan that copies the table's rows into a new table and drops the
/// old one, where the engine's ALTER TABLE cannot make the change.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TableRebuild {
    /// The indexes, triggers and views the plan drops, with the table or
    /// on their own, and makes again from the SQL the schema stored.
    pub recreated: Vec<RecreatedObject>,
    /// The copied rows get new rowids, so anything outside the schema
    /// that kept one no longer finds its row.
    pub renumbers_rowids: bool,
    /// A column that becomes the rowid, by its final name. SQLite gives a
    /// NULL copied into it a new number, so the plan stops instead when
    /// the column holds one.
    pub numbered_column: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecreatedObject {
    pub kind: SchemaObjectKind,
    pub name: String,
}
