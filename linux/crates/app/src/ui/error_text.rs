use tablepro_core::DriverError;
#[cfg(test)]
use tablepro_core::sql_dialect::BuildSqlError;
use tablepro_ssh::russh_tunnel::SshError;

#[cfg(test)]
pub fn build_sql_message(error: &BuildSqlError) -> String {
    match error {
        BuildSqlError::NoPrimaryKey => {
            crate::i18n::gettext("This table has no primary key. Use the modal Edit dialog instead.")
        }
        BuildSqlError::NothingToUpdate => crate::i18n::gettext("No changes to save."),
        BuildSqlError::LengthMismatch { expected, got } => crate::i18n::gettext_f(
            "Internal column count mismatch (expected {expected}, got {got}).",
            &[("expected", &expected.to_string()), ("got", &got.to_string())],
        ),
    }
}

pub fn ssh_message(error: &SshError) -> String {
    match error {
        SshError::RequiresOpenSsh { setting } => crate::i18n::gettext_f(
            "This connection uses {setting}, which needs a newer TablePro.",
            &[("setting", setting)],
        ),
        other => crate::i18n::gettext_f("SSH tunnel failed: {detail}", &[("detail", &other.to_string())]),
    }
}

pub fn driver_message(error: &DriverError) -> String {
    match error {
        DriverError::ConnectionRefused => crate::i18n::gettext("Could not reach the database. Is it running?"),
        DriverError::AuthFailed => crate::i18n::gettext("Username or password is wrong."),
        DriverError::Tls(detail) => crate::i18n::gettext_f("TLS handshake failed: {detail}", &[("detail", detail)]),
        DriverError::Query {
            message,
            sqlstate: Some(s),
        } => crate::i18n::gettext_f(
            "Query failed (SQLSTATE {sqlstate}): {message}",
            &[("sqlstate", s), ("message", message)],
        ),
        DriverError::Query { message, .. } => {
            crate::i18n::gettext_f("Query failed: {message}", &[("message", message)])
        }
        DriverError::Disconnected => crate::i18n::gettext("The connection was closed. Try reconnecting."),
        DriverError::ReadOnly => {
            crate::i18n::gettext("This connection is read-only. Reopen it without read-only mode to make changes.")
        }
        DriverError::Internal(detail) => {
            crate::i18n::gettext_f("Internal driver error: {detail}", &[("detail", detail)])
        }
        DriverError::IntegratedAuth(detail) => crate::i18n::gettext_f(
            "Kerberos login failed: {detail}. Check that klist shows a valid ticket, run kinit if it does not, and make sure the server's SPN matches the host you typed.",
            &[("detail", detail)],
        ),
        DriverError::Transaction {
            statement_index,
            source,
        } => crate::i18n::gettext_f(
            "Save failed at statement {n}: {error}. The transaction was rolled back; no rows were changed.",
            &[
                ("n", &(statement_index + 1).to_string()),
                ("error", &driver_message(source)),
            ],
        ),
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

    #[test]
    fn integrated_auth_names_the_remedy_and_keeps_the_gssapi_detail() {
        let message = driver_message(&DriverError::IntegratedAuth("No Kerberos credentials available".into()));
        assert!(message.contains("No Kerberos credentials available"));
        assert!(message.contains("kinit"));
        assert!(message.contains("SPN"));
    }
}

/// What to tell the user about a keyring failure. Each variant maps to
/// a different next step, so they are not collapsed into one sentence.
pub fn secret_message(error: &tablepro_core::credentials::SecretError) -> String {
    use tablepro_core::credentials::SecretError;

    match error {
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so saved passwords cannot be read. Start a keyring, or enter the password by hand.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so saved passwords cannot be read inside the sandbox.",
        ),
        SecretError::Locked => crate::i18n::gettext("The keyring is locked. Unlock it and try again."),
        SecretError::UnlockDismissed => {
            crate::i18n::gettext("The keyring stayed locked because the unlock prompt was dismissed.")
        }
        SecretError::InvalidEncoding => {
            crate::i18n::gettext("The stored password is not readable text. Enter it again to replace it.")
        }
        SecretError::Backend { detail } => {
            crate::i18n::gettext_f("The keyring reported: {detail}", &[("detail", detail)])
        }
    }
}

#[cfg(test)]
mod secret_message_tests {
    use tablepro_core::credentials::SecretError;

    use super::*;

    #[test]
    fn every_secret_error_has_its_own_message() {
        let errors = [
            SecretError::ServiceUnavailable { detail: "x".to_owned() },
            SecretError::PortalUnavailable { detail: "x".to_owned() },
            SecretError::Locked,
            SecretError::UnlockDismissed,
            SecretError::InvalidEncoding,
            SecretError::Backend {
                detail: "boom".to_owned(),
            },
        ];

        let messages: std::collections::HashSet<String> = errors.iter().map(secret_message).collect();

        assert_eq!(messages.len(), errors.len(), "two errors share a message");
        for message in &messages {
            assert!(!message.is_empty());
        }
    }

    #[test]
    fn a_backend_error_keeps_its_detail() {
        let message = secret_message(&SecretError::Backend {
            detail: "org.freedesktop.Secret failed".to_owned(),
        });

        assert!(message.contains("org.freedesktop.Secret failed"), "{message}");
    }

    #[test]
    fn a_retryable_error_says_to_try_again() {
        assert!(secret_message(&SecretError::Locked).contains("try again"));
    }
}
