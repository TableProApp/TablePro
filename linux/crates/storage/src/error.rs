use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("{}: {source}", .path.display())]
    Io {
        path: std::path::PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("could not write {}: {source}", .path.display())]
    Write {
        path: std::path::PathBuf,
        #[source]
        source: glib::Error,
    },

    #[error("could not set permissions on {}: {source}", .path.display())]
    Permissions {
        path: std::path::PathBuf,
        #[source]
        source: std::io::Error,
    },

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

    #[error("a name is required")]
    EmptyName,

    #[error("export encoding failed: {0}")]
    Encode(#[from] tablepro_core::export::EncodeError),

    #[error("settings error: {0}")]
    Settings(#[from] crate::settings::SettingsError),

    #[error("the query history was created by a newer version of TablePro (schema {version})")]
    HistoryNewerThanApp { version: i64 },

    #[error("could not migrate the query history: {0}")]
    HistoryMigration(#[source] sqlx::migrate::MigrateError),

    #[error("{0}")]
    DocumentUnavailable(#[source] crate::document_problem::DocumentProblem),

    #[error("{} is not valid UTF-8 from byte {offset}", .path.display())]
    DraftNotUtf8 { path: std::path::PathBuf, offset: usize },
}
