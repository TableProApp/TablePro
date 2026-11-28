use thiserror::Error;

/// Why a table draft cannot be saved as it stands, found before any SQL
/// is written.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Error)]
pub enum DraftProblem {
    #[error("the table name is empty")]
    EmptyTableName,
    #[error("the table has no columns")]
    NoColumns,
    #[error("a column has no name")]
    EmptyColumnName,
    #[error("two columns are named {0}")]
    DuplicateColumnName(String),
    #[error("column {0} has no type")]
    EmptyColumnType(String),
    #[error("primary key column {0} takes NULL")]
    NullablePrimaryKey(String),
    /// An engine whose every table needs a primary key, as CQL's does.
    #[error("the table has no primary key")]
    NoPrimaryKey,
    /// An index or foreign key the draft keeps names a column it no
    /// longer has.
    #[error("column {column} is gone but {} still use it", used_by.join(", "))]
    ColumnInUse { column: String, used_by: Vec<String> },
    #[error("an index has no name")]
    EmptyIndexName,
    #[error("index {0} has no keys")]
    IndexWithoutKeys(String),
    #[error("a foreign key has no name")]
    EmptyForeignKeyName,
    #[error("foreign key {0} pairs a different number of columns on each side")]
    ForeignKeyColumnMismatch(String),
}

impl DraftProblem {
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyTableName => "draft.empty_table_name",
            Self::NoColumns => "draft.no_columns",
            Self::EmptyColumnName => "draft.empty_column_name",
            Self::DuplicateColumnName(_) => "draft.duplicate_column_name",
            Self::EmptyColumnType(_) => "draft.empty_column_type",
            Self::NullablePrimaryKey(_) => "draft.nullable_primary_key",
            Self::NoPrimaryKey => "draft.no_primary_key",
            Self::ColumnInUse { .. } => "draft.column_in_use",
            Self::EmptyIndexName => "draft.empty_index_name",
            Self::IndexWithoutKeys(_) => "draft.index_without_keys",
            Self::EmptyForeignKeyName => "draft.empty_foreign_key_name",
            Self::ForeignKeyColumnMismatch(_) => "draft.foreign_key_column_mismatch",
        }
    }
}
