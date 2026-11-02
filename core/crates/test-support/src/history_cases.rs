//! Statements every engine's dialect has to let into the query history.

use tablepro_core::dialect::SqlDialect;
use tablepro_core::sql_syntax::HistoryRecording;

/// SQL that names passwords, secrets or a carrier without setting a
/// credential, so withholding any of it would only lose history.
pub const PLAIN_STATEMENTS: [&str; 7] = [
    "SELECT id FROM users WHERE password IS NULL AND email = 'a@b'",
    "UPDATE accounts SET secret = NULL WHERE name = 'x'",
    "DELETE FROM creds WHERE password = 'p'",
    "SELECT 'password' AS label",
    "CREATE TABLE s3 (id int)",
    "SELECT s3 FROM t",
    "-- only a note\n/* and another */",
];

/// The plain statements `dialect` would not record, for a test to
/// expect none of.
pub fn unrecorded_plain_statements(dialect: &dyn SqlDialect) -> Vec<&'static str> {
    PLAIN_STATEMENTS
        .into_iter()
        .filter(|sql| dialect.history_recording(sql) != HistoryRecording::Record)
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::WithholdReason;

    use super::*;
    use crate::FakeDialect;

    #[test]
    fn the_fake_dialect_records_plain_statements() {
        assert_eq!(unrecorded_plain_statements(&FakeDialect), Vec::<&str>::new());
    }

    #[test]
    fn the_fake_dialect_withholds_a_login() {
        assert_eq!(
            FakeDialect.history_recording("SELECT 1; CREATE USER u PASSWORD 'p'"),
            HistoryRecording::Withhold(WithholdReason::CredentialStatement)
        );
    }
}
