use std::io::ErrorKind;

use tablepro_storage::StorageError;

/// Whether the query history is usable yet.
///
/// The database opens in the background, so the menu item that needs it
/// stays disabled until it is `Ready` instead of opening a dialog that
/// cannot search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryAvailability {
    Starting,
    Ready,
    /// The database could not be opened, and why, as the user is told.
    Failed(String),
}

impl HistoryAvailability {
    pub fn failed(error: &StorageError) -> Self {
        Self::Failed(open_failure_text(error))
    }

    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready)
    }

    /// Done opening, one way or the other.
    pub fn is_settled(&self) -> bool {
        !matches!(self, Self::Starting)
    }

    pub fn failure(&self) -> Option<&str> {
        match self {
            Self::Failed(detail) => Some(detail),
            _ => None,
        }
    }
}

/// Query history and saved queries share the one database, so this
/// names both.
fn open_failure_text(error: &StorageError) -> String {
    match error {
        StorageError::HistoryNewerThanApp { .. } => crate::i18n::gettext(
            "The query history was written by a newer version of TablePro. Update TablePro to read it.",
        ),
        StorageError::HistoryMigration(_) => {
            crate::i18n::gettext("The query history could not be updated for this version of TablePro.")
        }
        StorageError::Io { path, source } | StorageError::Permissions { path, source } => {
            let path = path.display().to_string();
            match source.kind() {
                ErrorKind::PermissionDenied | ErrorKind::ReadOnlyFilesystem => {
                    crate::i18n::gettext_f("TablePro is not allowed to write {path}.", &[("path", &path)])
                }
                ErrorKind::StorageFull | ErrorKind::QuotaExceeded => {
                    crate::i18n::gettext_f("The disk that holds {path} is full.", &[("path", &path)])
                }
                _ => crate::i18n::gettext_f("{path} could not be created.", &[("path", &path)]),
            }
        }
        _ => crate::i18n::gettext("The query history file could not be read. It may be damaged."),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn io(kind: ErrorKind) -> StorageError {
        StorageError::Io {
            path: PathBuf::from("/home/ada/.local/state/tablepro/history.db"),
            source: std::io::Error::from(kind),
        }
    }

    #[test]
    fn the_reason_says_what_to_fix_without_the_raw_error() {
        assert_eq!(
            HistoryAvailability::failed(&io(ErrorKind::PermissionDenied)).failure(),
            Some("TablePro is not allowed to write /home/ada/.local/state/tablepro/history.db.")
        );
        assert_eq!(
            HistoryAvailability::failed(&io(ErrorKind::StorageFull)).failure(),
            Some("The disk that holds /home/ada/.local/state/tablepro/history.db is full.")
        );
        assert_eq!(
            HistoryAvailability::failed(&StorageError::HistoryNewerThanApp { version: 9 }).failure(),
            Some("The query history was written by a newer version of TablePro. Update TablePro to read it.")
        );
        assert_eq!(
            HistoryAvailability::failed(&StorageError::NotInitialised).failure(),
            Some("The query history file could not be read. It may be damaged.")
        );
    }
}
