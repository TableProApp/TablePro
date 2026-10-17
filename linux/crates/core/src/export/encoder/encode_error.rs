use thiserror::Error;

/// Why a row could not be encoded. The text is for logs; the app says it
/// in its own words.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EncodeError {
    #[error("column {column} has an undecodable value")]
    Undecodable { column: String },

    /// A control character XML 1.0 has no representation for, not even
    /// as a character reference.
    #[error("column {column} holds a character XML cannot carry")]
    NotXmlText { column: String },
}
