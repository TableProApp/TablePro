use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("schema error: {0}")]
    Schema(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("history not initialised")]
    NotInitialised,

    #[error("query exceeds {limit} bytes (got {got})")]
    TooLarge { got: usize, limit: usize },

    #[error("not found")]
    NotFound,

    #[error("export encoding failed: {0}")]
    Encode(#[from] tablepro_core::export::EncodeError),
}
