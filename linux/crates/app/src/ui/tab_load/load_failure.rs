use std::sync::Arc;

use tablepro_core::ErrorCategory;
use tablepro_session::OperationError;

/// Why a tab's read showed nothing new.
#[derive(Debug, Clone)]
pub(crate) enum LoadFailure {
    /// The table's columns, or what tells its rows apart.
    Columns(Arc<OperationError>),
    /// The catalog lists no column the account can read.
    NoColumns,
    /// The page came back with other columns than the ones read for it,
    /// and again after they were read again.
    ColumnsChanged,
    Page(Arc<OperationError>),
    /// The table's definition, for the structure tab.
    Definition(Arc<OperationError>),
    /// A schema's tables or one of them, for the diagram.
    Schema(Arc<OperationError>),
    /// The key a key tab shows is gone: deleted, renamed or expired.
    KeyMissing,
}

impl LoadFailure {
    /// Plain text: a server's message can hold `<` and `&`, so whatever
    /// shows it must not read it as markup.
    pub(crate) fn message(&self) -> String {
        match self {
            Self::Columns(error) | Self::Page(error) | Self::Definition(error) | Self::Schema(error) => {
                crate::ui::error_text::operation_error_message(error)
            }
            Self::NoColumns => crate::i18n::gettext(
                "This table has no columns you can read. It may have been dropped, or your account can't read it.",
            ),
            Self::ColumnsChanged => crate::i18n::gettext(
                "The table's columns changed while its rows were read. Try again to read it as it is now.",
            ),
            Self::KeyMissing => {
                crate::i18n::gettext("This key no longer exists. It may have been deleted or renamed, or it expired.")
            }
        }
    }

    /// What kind of problem it was, for the log, which never takes the
    /// server's text.
    pub(crate) fn category(&self) -> Option<ErrorCategory> {
        match self {
            Self::Columns(error) | Self::Page(error) | Self::Definition(error) | Self::Schema(error) => {
                error.category()
            }
            Self::NoColumns | Self::ColumnsChanged | Self::KeyMissing => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{DriverError, LossPhase, TimeoutPhase};

    use super::*;

    #[test]
    fn load_failure_message_uses_error_category() {
        let lost = LoadFailure::Page(Arc::new(OperationError::Driver(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        })));
        let timed_out = LoadFailure::Columns(Arc::new(OperationError::Driver(DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        })));

        assert_eq!(lost.message(), "The connection was closed. Try reconnecting.");
        assert_eq!(
            timed_out.message(),
            "The statement ran past its time limit, so the server stopped it."
        );
    }

    #[test]
    fn no_columns_failure_message() {
        assert_eq!(
            LoadFailure::NoColumns.message(),
            "This table has no columns you can read. It may have been dropped, or your account can't read it."
        );
        assert_eq!(LoadFailure::NoColumns.category(), None);
    }

    #[test]
    fn a_server_message_stays_plain_text() {
        let failure = LoadFailure::Page(Arc::new(OperationError::Driver(DriverError::server(
            "relation <b>users</b> & co",
        ))));

        assert!(failure.message().contains("<b>users</b> & co"), "{}", failure.message());
    }
}
