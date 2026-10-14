use thiserror::Error;

/// Why a row could not be encoded. The text is for logs; the app says it
/// in its own words.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EncodeError {
    #[error("column {column} has an undecodable value")]
    Undecodable { column: String },
}
