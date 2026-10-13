use tablepro_storage::document::VersionedDocument;
use tablepro_storage::{DocumentProblem, DocumentProblemKind};
use thiserror::Error;

use super::WorkspaceRecord;

/// Why a session's saved tabs could not be used. The file is left as it
/// is in every case, so a fix or an upgrade can still bring them back.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WorkspaceLoadError {
    #[error("the saved tabs could not be read: {0}")]
    Io(String),
    #[error("the saved tabs are not valid: {0}")]
    Corrupt(String),
    #[error("the saved tabs are in a format this version does not read (found {found:?}, reads {expected})")]
    UnsupportedVersion { found: Option<u32>, expected: u32 },
}

impl From<DocumentProblem> for WorkspaceLoadError {
    fn from(problem: DocumentProblem) -> Self {
        match problem.kind {
            DocumentProblemKind::Unreadable { detail } => Self::Io(detail),
            DocumentProblemKind::Corrupt { detail, .. } => Self::Corrupt(detail),
            DocumentProblemKind::MissingVersion => Self::UnsupportedVersion {
                found: None,
                expected: WorkspaceRecord::VERSION,
            },
            DocumentProblemKind::UnsupportedVersion { found, expected }
            | DocumentProblemKind::NewerVersion { found, expected } => Self::UnsupportedVersion {
                found: Some(found),
                expected,
            },
        }
    }
}
