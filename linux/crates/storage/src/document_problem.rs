use std::path::PathBuf;

use thiserror::Error;

/// Why a stored document could not be used. The store keeps the file
/// untouched in every one of these cases: overwriting it would destroy
/// whatever the user could still recover.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("{}: {kind}", .path.display())]
pub struct DocumentProblem {
    pub path: PathBuf,
    pub kind: DocumentProblemKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DocumentProblemKind {
    #[error("the file could not be read: {detail}")]
    Unreadable { detail: String },
    #[error("the file is not valid JSON at line {line}, column {column}: {detail}")]
    Corrupt { detail: String, line: usize, column: usize },
    #[error("the file has no version field")]
    MissingVersion,
    #[error("the file is version {found}, which this version of TablePro no longer reads")]
    UnsupportedVersion { found: u32, expected: u32 },
    #[error("the file is version {found}, which is newer than this version of TablePro understands")]
    NewerVersion { found: u32, expected: u32 },
}

impl DocumentProblem {
    pub fn new(path: impl Into<PathBuf>, kind: DocumentProblemKind) -> Self {
        Self {
            path: path.into(),
            kind,
        }
    }

    /// Whether a newer TablePro wrote the file. The banner says so
    /// differently, because upgrading fixes it and resetting loses data.
    pub fn is_newer_version(&self) -> bool {
        matches!(self.kind, DocumentProblemKind::NewerVersion { .. })
    }
}
