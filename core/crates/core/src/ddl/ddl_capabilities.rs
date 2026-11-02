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
    /// Whether an index keeps a key in descending order. DuckDB takes
    /// `DESC` in CREATE INDEX and drops it.
    pub descending_index_keys: bool,
    pub partial_indexes: bool,
    pub add_foreign_key: bool,
    pub drop_foreign_key: bool,
    /// Whether a column can carry a comment. SQLite drops one from the
    /// CREATE TABLE text, so it has nowhere to keep it.
    pub column_comments: bool,
    pub drop_table_cascade: bool,
    /// Whether a column can carry a default at all. CQL has none.
    pub column_defaults: bool,
    /// Whether a column outside the primary key can refuse NULL. CQL
    /// has no NOT NULL.
    pub required_columns: bool,
    /// Whether a table lists its columns in the order they were declared
    /// and added. CQL lists the key columns first and the rest by name.
    pub declared_column_order: bool,
    /// Whether the user picks a column's character set and collation from
    /// the server's list (`Connection::fetch_character_sets`).
    pub column_collations: bool,
    /// Whether the table's default character set and collation, a
    /// convert of every column to them, and the next AUTO_INCREMENT value
    /// can change (`TableChanges::options`).
    pub table_options: bool,
}
