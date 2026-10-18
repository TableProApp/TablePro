use thiserror::Error;

/// Why a COLUMN_TYPE did not scan. The column then classifies as
/// `Other` with its declaration kept verbatim, never as a guess.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub(crate) enum ColumnTypeScanError {
    #[error("{column_type:?} does not start with its DATA_TYPE {data_type:?}")]
    MissingDataTypePrefix { data_type: String, column_type: String },
    #[error("{0:?} has an unbalanced parenthesis or an unterminated label")]
    Unbalanced(String),
    #[error("{0:?} is not a modifier this scanner knows")]
    UnexpectedModifier(String),
}
