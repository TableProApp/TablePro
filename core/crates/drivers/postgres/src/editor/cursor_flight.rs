//! The SQL of the cursor flight, kept apart from the session so the
//! texts and the position arithmetic can be tested on their own.

use tablepro_core::{DriverError, RowLimit};

use crate::errors::sqlstate;

pub(crate) const CURSOR: &str = "tablepro_cursor";
pub(crate) const SAVEPOINT: &str = "SAVEPOINT tablepro_cursor_savepoint";
pub(crate) const ROLLBACK_TO_SAVEPOINT: &str = "ROLLBACK TO SAVEPOINT tablepro_cursor_savepoint";
pub(crate) const RELEASE_SAVEPOINT: &str = "RELEASE SAVEPOINT tablepro_cursor_savepoint";
pub(crate) const CLOSE: &str = "CLOSE tablepro_cursor";

/// The newline after FOR keeps a statement that starts with a comment
/// intact, and the FETCH goes in a message of its own, so a trailing
/// `--` comment in the statement cannot swallow it.
const DECLARE_PREFIX: &str = "DECLARE tablepro_cursor NO SCROLL CURSOR FOR\n";

pub(crate) fn declare(statement: &str) -> String {
    format!("{DECLARE_PREFIX}{statement}")
}

/// One row past the limit, so a full result is told apart from one cut
/// short without reading the rest.
pub(crate) fn fetch(limit: RowLimit) -> String {
    format!("FETCH FORWARD {} FROM {CURSOR}", limit.get().saturating_add(1))
}

/// A refusal that means the statement cannot be a cursor at all: a
/// data-modifying WITH (0A000), or SELECT INTO (42601). Nothing ran, so
/// the statement can go again as it is.
pub(crate) fn needs_plain_statement(error: &DriverError) -> bool {
    matches!(sqlstate(error), Some("0A000" | "42601"))
}

/// The server counts an error position in characters from the start of
/// the message it parsed, which here starts with the DECLARE. The user
/// wants it counted from the start of their own statement.
pub(crate) fn correct_position(error: DriverError) -> DriverError {
    let prefix = u32::try_from(DECLARE_PREFIX.chars().count()).unwrap_or(u32::MAX);
    match error {
        DriverError::Server(mut diagnostics) => {
            diagnostics.position = diagnostics
                .position
                .and_then(|position| position.checked_sub(prefix))
                .filter(|position| *position > 0);
            DriverError::Server(diagnostics)
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

    use super::*;

    fn syntax_error(code: &str, position: u32) -> DriverError {
        let mut diagnostics = ServerDiagnostics::new(Some(ServerCode::SqlState(code.to_owned())), "syntax error");
        diagnostics.position = Some(position);
        DriverError::reported(diagnostics)
    }

    #[test]
    fn error_position_is_corrected() {
        let prefix = u32::try_from(DECLARE_PREFIX.chars().count()).expect("a short prefix");
        let corrected = correct_position(syntax_error("42601", prefix + 8));

        let DriverError::Server(diagnostics) = corrected else {
            panic!("the error changed kind");
        };
        assert_eq!(diagnostics.position, Some(8));
    }

    #[test]
    fn the_fetch_asks_for_one_row_past_the_limit_in_its_own_message() {
        let limit = RowLimit::new(100).expect("a limit");

        assert_eq!(fetch(limit), "FETCH FORWARD 101 FROM tablepro_cursor");
        assert_eq!(
            declare("SELECT 1 -- trailing"),
            "DECLARE tablepro_cursor NO SCROLL CURSOR FOR\nSELECT 1 -- trailing"
        );
    }

    #[test]
    fn only_the_cursor_refusals_fall_back() {
        assert!(needs_plain_statement(&syntax_error("0A000", 1)));
        assert!(needs_plain_statement(&syntax_error("42601", 1)));
        assert!(!needs_plain_statement(&syntax_error("42P01", 1)));
    }
}
