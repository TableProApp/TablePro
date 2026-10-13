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
