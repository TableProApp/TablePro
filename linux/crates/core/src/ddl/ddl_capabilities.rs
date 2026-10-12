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
    /// Whether nullability can be switched in place. ClickHouse can
    /// only do it by rewriting the column's type as Nullable.
    pub nullability_switch: bool,
    pub alter_column_default: bool,
    pub alter_primary_key: bool,
    pub alter_auto_increment: bool,
    pub create_index: bool,
    pub drop_index: bool,
    pub expression_index_keys: bool,
    pub partial_indexes: bool,
    pub add_foreign_key: bool,
    pub drop_foreign_key: bool,
    pub drop_table_cascade: bool,
}
