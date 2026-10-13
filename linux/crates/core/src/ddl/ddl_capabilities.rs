/// Which structure changes an engine can make, so the structure tab
/// offers only those instead of failing at Save.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DdlCapabilities {
    pub create_table: bool,
    pub rename_table: bool,
    pub add_column: bool,
    pub drop_column: bool,
    pub rename_column: bool,
    pub alter_column_type: bool,
    pub alter_column_nullability: bool,
    pub alter_column_default: bool,
    pub alter_primary_key: bool,
    pub alter_auto_increment: bool,
    /// Whether a column numbers itself outside the primary key, as a
    /// PostgreSQL identity or a SQL Server IDENTITY does. Where it cannot,
    /// numbering goes off as the column leaves the key.
    pub auto_increment_outside_primary_key: bool,
    pub create_index: bool,
    pub drop_index: bool,
    pub expression_index_keys: bool,
    pub partial_indexes: bool,
    pub add_foreign_key: bool,
    pub drop_foreign_key: bool,
    /// Whether a column can carry a comment. SQLite drops one from the
    /// CREATE TABLE text, so it has nowhere to keep it.
    pub column_comments: bool,
    pub drop_table_cascade: bool,
}
