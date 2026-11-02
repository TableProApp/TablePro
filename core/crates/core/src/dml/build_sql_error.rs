use thiserror::Error;

use crate::dialect::BindError;

/// Why a row change could not be written as SQL.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BuildSqlError {
    #[error("this table has no way to name a single row")]
    NoRowIdentity,
    #[error("rows in this table cannot be edited, because nothing identifies one")]
    ReadOnlyRows,
    #[error("the row key names a column this table does not have: {name}")]
    UnknownKeyColumn { name: String },
    #[error("there is nothing to update")]
    NothingToUpdate,
    #[error("there is nothing to insert")]
    NoInsertValues,
    #[error("the row key has {found} values but the table needs {expected}")]
    LengthMismatch { expected: usize, found: usize },
    #[error("part of this row's key could not be read from the server, so the row cannot be changed")]
    UndecodableKey,
    /// A document field whose name has a dot or starts with `$`, which a
    /// sort or an update would read as a path or an operator.
    #[error("field {name} has a name an update or a sort cannot write")]
    UnaddressableField { name: String },
    /// A default or an expression where the engine's statement has no
    /// place for one.
    #[error("column {name} cannot be set to a value the server computes")]
    ServerComputedValue { name: String },
    #[error(transparent)]
    Bind(#[from] BindError),
}
