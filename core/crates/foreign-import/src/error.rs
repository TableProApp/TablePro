use std::path::PathBuf;

use thiserror::Error;

use crate::ForeignApp;

#[derive(Debug, Error)]
pub enum ForeignImportError {
    #[error("could not find {} data files", .app.display_name())]
    FileNotFound { app: ForeignApp },

    #[error("could not read {}: {source}", .path.display())]
    Unreadable {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("failed to parse connections: {detail}")]
    Parse { detail: String },

    #[error("unsupported file format: {detail}")]
    UnsupportedFormat { detail: String },

    #[error("no connections found to import")]
    NothingFound,

    #[error("the import was cancelled")]
    Cancelled,
}

impl ForeignImportError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::FileNotFound { .. } => "foreign_import.file_not_found",
            Self::Unreadable { .. } => "foreign_import.unreadable",
            Self::Parse { .. } => "foreign_import.parse",
            Self::UnsupportedFormat { .. } => "foreign_import.unsupported_format",
            Self::NothingFound => "foreign_import.nothing_found",
            Self::Cancelled => "foreign_import.cancelled",
        }
    }

    pub(crate) fn parse(detail: impl Into<String>) -> Self {
        Self::Parse { detail: detail.into() }
    }

    pub(crate) fn unsupported(detail: impl Into<String>) -> Self {
        Self::UnsupportedFormat { detail: detail.into() }
    }
}
