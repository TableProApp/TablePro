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
    #[error("the file is version {found} and could not be brought up to version {expected}: {detail}")]
    UpgradeFailed { found: u32, expected: u32, detail: String },
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

    pub fn code(&self) -> &'static str {
        match self.kind {
            DocumentProblemKind::Unreadable { .. } => "storage.document_unreadable",
            DocumentProblemKind::Corrupt { .. } => "storage.document_corrupt",
            DocumentProblemKind::MissingVersion => "storage.document_missing_version",
            DocumentProblemKind::UnsupportedVersion { .. } => "storage.document_unsupported_version",
            DocumentProblemKind::NewerVersion { .. } => "storage.document_newer_version",
            DocumentProblemKind::UpgradeFailed { .. } => "storage.document_upgrade_failed",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn each_problem_has_its_own_code() {
        let kinds = [
            DocumentProblemKind::Unreadable { detail: String::new() },
            DocumentProblemKind::Corrupt {
                detail: String::new(),
                line: 1,
                column: 1,
            },
            DocumentProblemKind::MissingVersion,
            DocumentProblemKind::UnsupportedVersion { found: 0, expected: 1 },
            DocumentProblemKind::NewerVersion { found: 2, expected: 1 },
            DocumentProblemKind::UpgradeFailed {
                found: 0,
                expected: 1,
                detail: String::new(),
            },
        ];
        let codes: HashSet<&str> = kinds
            .into_iter()
            .map(|kind| DocumentProblem::new("connections.json", kind).code())
            .collect();
        assert_eq!(codes.len(), 6, "{codes:?}");
        assert!(codes.iter().all(|code| code.starts_with("storage.document_")));
    }
}
