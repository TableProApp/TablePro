use tablepro_core::DriverError;
#[cfg(test)]
use tablepro_core::sql_dialect::BuildSqlError;

#[cfg(test)]
pub fn build_sql_message(error: &BuildSqlError) -> String {
    match error {
        BuildSqlError::NoPrimaryKey => crate::tr!("This table has no primary key. Use the modal Edit dialog instead."),
        BuildSqlError::NothingToUpdate => crate::tr!("No changes to save."),
        BuildSqlError::LengthMismatch { expected, got } => {
            crate::tr!("Internal column count mismatch (expected {expected}, got {got}).")
                .replace("{expected}", &expected.to_string())
                .replace("{got}", &got.to_string())
        }
    }
}

pub fn driver_message(error: &DriverError) -> String {
    match error {
        DriverError::ConnectionRefused => crate::tr!("Could not reach the database. Is it running?"),
        DriverError::AuthFailed => crate::tr!("Username or password is wrong."),
        DriverError::Tls(detail) => crate::tr!("TLS handshake failed: {detail}").replace("{detail}", detail),
        DriverError::Query {
            message,
            sqlstate: Some(s),
        } => crate::tr!("Query failed (SQLSTATE {sqlstate}): {message}")
            .replace("{sqlstate}", s)
            .replace("{message}", message),
        DriverError::Query { message, .. } => crate::tr!("Query failed: {message}").replace("{message}", message),
        DriverError::Disconnected => crate::tr!("The connection was closed. Try reconnecting."),
        DriverError::ReadOnly => {
            crate::tr!("This connection is read-only. Reopen it without read-only mode to make changes.")
        }
        DriverError::Internal(detail) => crate::tr!("Internal driver error: {detail}").replace("{detail}", detail),
        DriverError::Unsupported(detail) => {
            crate::tr!("Not supported by this build: {detail}").replace("{detail}", detail)
        }
        DriverError::Transaction {
            statement_index,
            source,
        } => {
            crate::tr!("Save failed at statement {n}: {error}. The transaction was rolled back; no rows were changed.")
                .replace("{n}", &(statement_index + 1).to_string())
                .replace("{error}", &driver_message(source))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_sql_messages_have_actionable_advice() {
        let nopk = build_sql_message(&BuildSqlError::NoPrimaryKey);
        assert!(nopk.contains("Edit dialog"));
        let nothing = build_sql_message(&BuildSqlError::NothingToUpdate);
        assert!(nothing.contains("No changes"));
        let mismatch = build_sql_message(&BuildSqlError::LengthMismatch { expected: 3, got: 2 });
        assert!(mismatch.contains("expected 3"));
        assert!(mismatch.contains("got 2"));
    }

    #[test]
    fn driver_messages_include_sqlstate_when_present() {
        let with_state = driver_message(&DriverError::Query {
            message: "duplicate key".into(),
            sqlstate: Some("23505".into()),
        });
        assert!(with_state.contains("23505"));
        let without = driver_message(&DriverError::Query {
            message: "syntax error".into(),
            sqlstate: None,
        });
        assert!(!without.contains("SQLSTATE"));
        assert!(without.contains("syntax error"));
    }

    #[test]
    fn driver_message_for_simple_variants() {
        assert!(driver_message(&DriverError::ConnectionRefused).contains("Could not reach"));
        assert!(driver_message(&DriverError::AuthFailed).contains("wrong"));
        assert!(driver_message(&DriverError::Disconnected).contains("Try reconnecting"));
    }
}
