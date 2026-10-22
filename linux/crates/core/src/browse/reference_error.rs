use thiserror::Error;

/// Why a foreign key leads nowhere from one row.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ReferenceError {
    /// A key with any NULL column is not checked against the other
    /// table under MATCH SIMPLE, so there is no row to point at.
    #[error("the key holds NULL in this row")]
    NullKey,
    #[error("the row has no column {column}")]
    MissingColumn { column: String },
    /// The catalogue gave the key's two sides different column counts,
    /// or none, as SQLite does for a key whose parent is gone.
    #[error("the columns of key {key} could not be read")]
    UnevenKey { key: String },
    /// The source table sits in a schema and the key names none, so the
    /// table it names could be any table of that name.
    #[error("the schema of {table} is not known")]
    UnknownSchema { table: String },
    #[error("the value of {column} has no text a filter can compare")]
    NoFilterText { column: String },
}

impl ReferenceError {
    /// The row has nothing to follow, rather than something that cannot
    /// be followed, so a menu offers nothing for it.
    pub fn leaves_nothing_to_follow(&self) -> bool {
        matches!(self, Self::NullKey | Self::MissingColumn { .. })
    }
}
