use tablepro_core::DriverError;
use tablepro_core::sql_dialect::BuildSqlError;

pub fn build_sql_message(error: &BuildSqlError) -> String {
    match error {
        BuildSqlError::NoPrimaryKey => crate::tr!("This table has no primary key. Use the modal Edit dialog instead."),
        BuildSqlError::NothingToUpdate => crate::tr!("No changes to save."),
        BuildSqlError::LengthMismatch { expected, got } => {
            crate::tr!("Internal column count mismatch (expected {expected}, got {got}).")
                .replace("{expected}", &expected.to_string())
                .replace("{got}", &got.to_string())
        }
        BuildSqlError::UnrepresentableValue { column } => {
            crate::tr!("Column {column} contains a value that cannot be copied into a SQL statement.")
                .replace("{column}", column)
        }
        BuildSqlError::UnsupportedDriver(driver) => {
            crate::tr!("Optimistic grid updates are not supported for {driver}.").replace("{driver}", driver)
        }
        BuildSqlError::StaleColumns => crate::tr!(
            "This table's columns changed after you started editing (for example, in a Structure tab). \
             Reload the page and reapply your changes."
        ),
    }
}

pub fn driver_message(error: &DriverError) -> String {
    match error {
        DriverError::ConnectionRefused => crate::tr!("Could not reach the database. Is it running?"),
        DriverError::AuthFailed => crate::tr!("Username or password is wrong."),
        DriverError::Tls(detail) => crate::tr!(
            "TLS handshake failed: {detail}. If this server does not use TLS, such as a local container, set TLS to Disabled."
        )
        .replace("{detail}", detail),
        DriverError::Query {
            message,
            sqlstate: Some(s),
            ..
        } => crate::tr!("Query failed (SQLSTATE {sqlstate}): {message}")
            .replace("{sqlstate}", s)
            .replace("{message}", message),
        DriverError::Query { message, .. } => crate::tr!("Query failed: {message}").replace("{message}", message),
        DriverError::Disconnected => crate::tr!("The connection was closed. Try reconnecting."),
        DriverError::ConcurrentModification => crate::tr!(
            "This row changed in the database after you loaded it. Your edits are still available; reload the row and reapply them."
        ),
        DriverError::ReadOnly => {
            crate::tr!("This connection is read-only. Reopen it without read-only mode to make changes.")
        }
        DriverError::PolicyDenied(detail) => crate::tr!("Blocked by policy: {detail}").replace("{detail}", detail),
        DriverError::Unsupported(detail) => {
            crate::tr!("This driver does not support: {detail}").replace("{detail}", detail)
        }
        DriverError::Internal(detail) => crate::tr!("Internal driver error: {detail}").replace("{detail}", detail),
        DriverError::Cancelled => crate::tr!("The operation was cancelled."),
        DriverError::TimedOut => crate::tr!("The operation timed out."),
        DriverError::OperationOutcomeUnknown { source } => crate::tr!(
            "The operation was interrupted, but the database outcome could not be confirmed: {detail}"
        )
        .replace("{detail}", &driver_message(source)),
        DriverError::IntegratedAuth(detail) => crate::tr!(
            "Kerberos login failed: {detail}. Check that klist shows a valid ticket, run kinit if it does not, and make sure the server's SPN matches the host you typed."
        )
        .replace("{detail}", detail),
        DriverError::Transaction {
            statement_index,
            source,
        } => {
            crate::tr!("Save failed at statement {n}: {error}. The rollback request succeeded; session state and other non-transactional side effects may remain.")
                .replace("{n}", &(statement_index + 1).to_string())
                .replace("{error}", &driver_message(source))
        }
        DriverError::TransactionRollbackFailed {
            statement_index,
            source,
            rollback_error,
        } => crate::tr!(
            "Save failed at statement {n}: {error}. Rollback also failed: {rollback_error}. Database changes may have been applied."
        )
        .replace("{n}", &(statement_index + 1).to_string())
        .replace("{error}", &driver_message(source))
        .replace("{rollback_error}", &driver_message(rollback_error)),
    }
}

pub fn keyring_message(failure: &tablepro_storage::KeyringFailure) -> String {
    use tablepro_storage::KeyringFailure;
    match failure {
        KeyringFailure::Unavailable => crate::tr!(
            "No keyring is running, so saved passwords can't be read. Start GNOME Keyring, KeePassXC with Secret Service, or another Secret Service provider, then try again."
        ),
        KeyringFailure::Locked => crate::tr!(
            "The keyring is locked. Unlock it, for example by signing in again or opening Passwords and Keys, then try again."
        ),
        KeyringFailure::UnlockCancelled => {
            crate::tr!(
                "Unlocking the keyring was cancelled, so the saved password was not read. Try again and unlock it when asked."
            )
        }
        KeyringFailure::Other(detail) => {
            crate::tr!("The keyring could not be used: {detail}").replace("{detail}", detail)
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_tls_failure_points_at_the_tls_setting() {
        let message = driver_message(&DriverError::Tls("certificate verify failed".into()));
        assert!(message.contains("certificate verify failed"));
        assert!(message.contains("set TLS to Disabled"));
    }

    #[test]
    fn each_keyring_failure_says_what_to_do_next() {
        use tablepro_storage::KeyringFailure;
        let texts: Vec<String> = [
            KeyringFailure::Unavailable,
            KeyringFailure::Locked,
            KeyringFailure::UnlockCancelled,
            KeyringFailure::Other("boom".into()),
        ]
        .iter()
        .map(keyring_message)
        .collect();
        assert!(texts[0].contains("Start"));
        assert!(texts[1].contains("Unlock"));
        assert!(texts[2].contains("Try again"));
        assert!(texts[3].contains("boom"));
    }

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
            position: None,
        });
        assert!(with_state.contains("23505"));
        let without = driver_message(&DriverError::Query {
            message: "syntax error".into(),
            sqlstate: None,
            position: None,
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

    #[test]
    fn failed_transaction_rollback_does_not_claim_no_changes() {
        let message = driver_message(&DriverError::TransactionRollbackFailed {
            statement_index: 2,
            source: Box::new(DriverError::Query {
                message: "statement failed".into(),
                sqlstate: None,
                position: None,
            }),
            rollback_error: Box::new(DriverError::Disconnected),
        });
        assert!(message.contains("statement 3"));
        assert!(message.contains("Rollback also failed"));
        assert!(message.contains("Database changes may have been applied"));
        assert!(!message.contains("no rows were changed"));
    }

    #[test]
    fn confirmed_rollback_warns_that_nontransactional_side_effects_may_remain() {
        let message = driver_message(&DriverError::Transaction {
            statement_index: 0,
            source: Box::new(DriverError::Query {
                message: "statement failed".into(),
                sqlstate: None,
                position: None,
            }),
        });
        assert!(message.contains("rollback request succeeded"));
        assert!(message.contains("session state and other non-transactional side effects may remain"));
        assert!(!message.contains("no rows were changed"));
    }

    #[test]
    fn integrated_auth_names_the_remedy_and_keeps_the_detail() {
        let message = driver_message(&DriverError::IntegratedAuth("No Kerberos credentials available".into()));
        assert!(message.contains("No Kerberos credentials available"));
        assert!(message.contains("kinit"));
        assert!(message.contains("SPN"));
    }
}
