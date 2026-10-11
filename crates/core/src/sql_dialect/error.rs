use thiserror::Error;

#[derive(Debug, Error)]
pub enum BuildSqlError {
    #[error("table has no primary key")]
    NoPrimaryKey,

    #[error("nothing to update")]
    NothingToUpdate,

    #[error("new_values length {got} does not match columns length {expected}")]
    LengthMismatch { expected: usize, got: usize },

    #[error("column {column} contains a value that cannot be represented in a SQL statement")]
    UnrepresentableValue { column: String },

    #[error("the table's columns changed since this edit was made; reload and reapply your changes")]
    StaleColumns,

    #[error("optimistic updates are unsupported for driver {0}")]
    UnsupportedDriver(String),
}
