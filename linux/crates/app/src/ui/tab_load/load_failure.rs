use std::sync::Arc;

use tablepro_session::OperationError;

/// Why a tab's read showed nothing new.
#[derive(Debug, Clone)]
pub(crate) enum LoadFailure {
    /// The table's columns, or what tells its rows apart.
    Columns(Arc<OperationError>),
    Page(Arc<OperationError>),
}

impl LoadFailure {
    /// Plain text: a server's message can hold `<` and `&`, so whatever
    /// shows it must not read it as markup.
    pub(crate) fn message(&self) -> String {
        match self {
            Self::Columns(error) | Self::Page(error) => crate::ui::error_text::operation_error_message(error),
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
    fn a_server_message_stays_plain_text() {
        let failure = LoadFailure::Page(Arc::new(OperationError::Driver(DriverError::server(
            "relation <b>users</b> & co",
        ))));

        assert!(failure.message().contains("<b>users</b> & co"), "{}", failure.message());
    }
}
