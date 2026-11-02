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
        source: std::io::Error,
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

    #[error("another saved query of the connection has that name")]
    NameTaken,

    #[error("another tag has that name")]
    TagNameTaken,

    #[error("export encoding failed: {0}")]
    Encode(#[from] tablepro_core::export::RenderError),

    #[error("the query history was created by a newer version of TablePro (schema {version})")]
    HistoryNewerThanApp { version: i64 },

    #[error("could not migrate the query history: {0}")]
    HistoryMigration(#[source] sqlx::migrate::MigrateError),

    #[error("{0}")]
    DocumentUnavailable(#[source] crate::document_problem::DocumentProblem),

    #[error("{} is not valid UTF-8 from byte {offset}", .path.display())]
    DraftNotUtf8 { path: std::path::PathBuf, offset: usize },

    #[error("the saved connections changed after the import was previewed")]
    ImportOutdated,
}

impl StorageError {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Io { .. } => "storage.io",
            Self::Write { .. } => "storage.write",
            Self::Permissions { .. } => "storage.permissions",
            Self::Serde(..) => "storage.serde",
            Self::Schema(..) => "storage.schema",
            Self::Database(..) => "storage.database",
            Self::NotInitialised => "storage.not_initialised",
            Self::TooLarge { .. } => "storage.too_large",
            Self::NotFound => "storage.not_found",
            Self::EmptyName => "storage.empty_name",
            Self::NameTaken => "storage.name_taken",
            Self::TagNameTaken => "storage.tag_name_taken",
            Self::Encode(..) => "storage.encode",
            Self::HistoryNewerThanApp { .. } => "storage.history_newer_than_app",
            Self::HistoryMigration(..) => "storage.history_migration",
            Self::DocumentUnavailable(..) => "storage.document_unavailable",
            Self::DraftNotUtf8 { .. } => "storage.draft_not_utf8",
            Self::ImportOutdated => "storage.import_outdated",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_error_names_its_variant_with_a_code_that_does_not_change() {
        assert_eq!(StorageError::NotFound.code(), "storage.not_found");
        assert_eq!(
            StorageError::HistoryNewerThanApp { version: 9 }.code(),
            "storage.history_newer_than_app"
        );
        assert_eq!(crate::CredentialError::Cancelled.code(), "credential.cancelled");
    }
}
