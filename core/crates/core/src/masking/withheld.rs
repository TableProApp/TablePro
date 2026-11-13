use crate::error::DriverError;

// A server's message can repeat a value the statement read, as PostgreSQL's `invalid input syntax for type integer:
// "..."` does, so a connection with masking rules sends it nowhere outside the grid. What failed before the server
// took the statement is the app's own and keeps its words.
pub fn may_repeat_a_value(error: &DriverError) -> bool {
    match error {
        DriverError::Server(_)
        | DriverError::Auth { .. }
        | DriverError::LoginRefused(_)
        | DriverError::Decode { .. }
        | DriverError::Protocol(_) => true,
        DriverError::RolledBack { source, .. }
        | DriverError::PartiallyApplied { source, .. }
        | DriverError::CommitOutcomeUnknown { source, .. } => may_repeat_a_value(source),
        _ => false,
    }
}

// The code the server gave, which is all such an error keeps.
pub fn server_code(error: &DriverError) -> Option<String> {
    match error {
        DriverError::Server(diagnostics) | DriverError::LoginRefused(diagnostics) => {
            diagnostics.code.as_ref().map(ToString::to_string)
        }
        DriverError::Auth { diagnostics } => diagnostics.as_ref()?.code.as_ref().map(ToString::to_string),
        DriverError::RolledBack { source, .. }
        | DriverError::PartiallyApplied { source, .. }
        | DriverError::CommitOutcomeUnknown { source, .. } => server_code(source),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server_diagnostics::{ServerCode, ServerDiagnostics};

    fn refused() -> DriverError {
        DriverError::Server(Box::new(ServerDiagnostics::new(
            Some(ServerCode::SqlState("22P02".to_owned())),
            r#"invalid input syntax for type integer: "ann@example.com""#,
        )))
    }

    #[test]
    fn the_server_s_words_may_repeat_a_value_and_keep_only_their_code() {
        let rolled_back = DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(refused()),
        };

        assert!(may_repeat_a_value(&refused()));
        assert!(may_repeat_a_value(&rolled_back));
        assert_eq!(server_code(&rolled_back).as_deref(), Some("22P02"));
    }

    #[test]
    fn the_app_s_own_failures_keep_their_words() {
        assert!(!may_repeat_a_value(&DriverError::Cancelled));
        assert!(!may_repeat_a_value(&DriverError::EditorSessionBusy));
        assert_eq!(server_code(&DriverError::Cancelled), None);
    }
}
