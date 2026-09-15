#[cfg(test)]
use tablepro_core::sql_dialect::BuildSqlError;
use tablepro_core::{DriverError, ReadOnlyRefusal, TlsFailure, TransportError};
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
        DriverError::Transport(transport) => transport_message(transport),
        DriverError::Auth { diagnostics } => match diagnostics {
            Some(diagnostics) => crate::i18n::gettext_f(
                "Username or password is wrong. The server said: {detail}",
                &[("detail", &diagnostics.message)],
            ),
            None => crate::i18n::gettext("Username or password is wrong."),
        },
        DriverError::IntegratedAuth(detail) => crate::i18n::gettext_f(
            "Kerberos login failed: {detail}. Check that klist shows a valid ticket, run kinit if it does not, and make sure the server's SPN matches the host you typed.",
            &[("detail", detail)],
        ),
        DriverError::Tls { failure, detail } => tls_message(*failure, detail),
        DriverError::Server(diagnostics) => match diagnostics.sqlstate() {
            Some(sqlstate) => crate::i18n::gettext_f(
                "Query failed (SQLSTATE {sqlstate}): {message}",
                &[("sqlstate", sqlstate), ("message", &diagnostics.message)],
            ),
            None => crate::i18n::gettext_f("Query failed: {message}", &[("message", &diagnostics.message)]),
        },
        DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard) => {
            crate::i18n::gettext("This connection is read-only. Reopen it without read-only mode to make changes.")
        }
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => crate::i18n::gettext_f(
            "The server refused the write: {message}",
            &[("message", &diagnostics.message)],
        ),
        DriverError::Cancelled => crate::i18n::gettext("Stopped."),
        DriverError::Timeout { phase, .. } => {
            crate::i18n::gettext_f("Timed out while {phase}.", &[("phase", &phase.to_string())])
        }
        DriverError::ConnectionLost { .. } => crate::i18n::gettext("The connection was closed. Try reconnecting."),
        DriverError::RolledBack {
            statement_index,
            source,
        } => crate::i18n::gettext_f(
            "Save failed at statement {n}: {error}. The transaction was rolled back; no rows were changed.",
            &[
                ("n", &(statement_index + 1).to_string()),
                ("error", &driver_message(source)),
            ],
        ),
        DriverError::RowGuardFailed { expected, actual, .. } => crate::i18n::gettext_f(
            "The save matched {actual} rows where it expected {expected}, so the row is not the one that was loaded. Nothing was changed; reload and try again.",
            &[("actual", &actual.to_string()), ("expected", &expected.to_string())],
        ),
        DriverError::GuardUnsupported { .. } => crate::i18n::gettext(
            "This database does not report how many rows a statement changed, so the save cannot be checked. Use a table with a primary key.",
        ),
        DriverError::CommitOutcomeUnknown { .. } => crate::i18n::gettext(
            "The connection was lost after the save was sent, so whether it was applied is not known. Reload to see what the server has.",
        ),
        DriverError::PartiallyApplied {
            applied,
            statement_index,
            ..
        } => crate::i18n::gettext_f(
            "{applied} of the save's statements were applied before statement {n} failed, and this database has no transaction to undo them. Reload to see what the server has.",
            &[
                ("applied", &applied.to_string()),
                ("n", &(statement_index + 1).to_string()),
            ],
        ),
        DriverError::FileNotFound { path } => {
            crate::i18n::gettext_f("No database file at {path}.", &[("path", &path.display().to_string())])
        }
        DriverError::FileAccessDenied { path } => crate::i18n::gettext_f(
            "No permission to open {path}.",
            &[("path", &path.display().to_string())],
        ),
        DriverError::NotADatabase { path } => crate::i18n::gettext_f(
            "{path} is not a database file.",
            &[("path", &path.display().to_string())],
        ),
        DriverError::Busy => {
            crate::i18n::gettext("The server has no room for another connection right now. Try again shortly.")
        }
        DriverError::EditorSessionBusy => {
            crate::i18n::gettext("This tab is still running a statement. Stop it or wait for it to finish.")
        }
        DriverError::Decode { column, detail } => crate::i18n::gettext_f(
            "Could not read column {column}: {detail}",
            &[("column", column), ("detail", detail)],
        ),
        DriverError::Protocol(detail) => crate::i18n::gettext_f(
            "The driver could not read the server's reply: {detail}",
            &[("detail", detail)],
        ),
        DriverError::Unsupported { feature } => {
            crate::i18n::gettext_f("This database has no {feature}.", &[("feature", feature)])
        }
        // The enum grows with the drivers, and a variant added later
        // still has a sentence of its own to show.
        other => other.to_string(),
    }
}

fn transport_message(error: &TransportError) -> String {
    match error {
        TransportError::Refused { endpoint } => crate::i18n::gettext_f(
            "{host}:{port} refused the connection. Is the database running?",
            &[("host", endpoint.host()), ("port", &endpoint.port().to_string())],
        ),
        TransportError::NameResolution { host, .. } => {
            crate::i18n::gettext_f("Could not look up {host}.", &[("host", host)])
        }
        TransportError::Unreachable { endpoint, .. } => crate::i18n::gettext_f(
            "Could not reach {host}:{port}.",
            &[("host", endpoint.host()), ("port", &endpoint.port().to_string())],
        ),
        TransportError::Timeout { phase } => {
            crate::i18n::gettext_f("Timed out while {phase}.", &[("phase", &phase.to_string())])
        }
        other => other.to_string(),
    }
}

/// Each TLS failure has a different next step, which is the whole point
/// of telling them apart.
fn tls_message(failure: TlsFailure, detail: &str) -> String {
    match failure {
        TlsFailure::UnknownIssuer => crate::i18n::gettext(
            "The server's certificate was signed by an authority this machine does not know. Choose a CA certificate for this connection.",
        ),
        TlsFailure::NameMismatch => crate::i18n::gettext(
            "The server's certificate is for a different name. Set the TLS server name to the one on the certificate.",
        ),
        TlsFailure::Expired => crate::i18n::gettext("The server's certificate has expired."),
        TlsFailure::NotYetValid => crate::i18n::gettext("The server's certificate is not valid yet."),
        TlsFailure::Revoked => crate::i18n::gettext("The server's certificate was revoked."),
        TlsFailure::ServerRefusedTls => crate::i18n::gettext("The server does not accept TLS on this port."),
        TlsFailure::ServerRequiresTls => {
            crate::i18n::gettext("The server requires TLS. Turn TLS on for this connection.")
        }
        TlsFailure::CaFileInvalid => crate::i18n::gettext("The chosen CA certificate file could not be read."),
        TlsFailure::ClientIdentityInvalid => crate::i18n::gettext("The client certificate or key could not be read."),
        _ => crate::i18n::gettext_f("TLS failed: {detail}", &[("detail", detail)]),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

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
        let with_state = driver_message(&DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::SqlState("23505".to_owned())),
            "duplicate key",
        )));
        assert!(with_state.contains("23505"));

        let without = driver_message(&DriverError::reported(ServerDiagnostics::new(None, "syntax error")));
        assert!(!without.contains("SQLSTATE"));
        assert!(without.contains("syntax error"));
    }

    #[test]
    fn a_refused_connection_names_the_server_it_tried() {
        let endpoint = tablepro_core::NetworkEndpoint::new("db.internal", 5432).expect("an endpoint");

        let message = driver_message(&DriverError::Transport(TransportError::Refused { endpoint }));

        assert!(message.contains("db.internal:5432"), "{message}");
    }

    #[test]
    fn driver_message_for_simple_variants() {
        assert!(driver_message(&DriverError::auth(None)).contains("wrong"));
        assert!(
            driver_message(&DriverError::ConnectionLost {
                during: tablepro_core::LossPhase::Statement
            })
            .contains("Try reconnecting")
        );
        assert!(driver_message(&DriverError::Busy).contains("no room"));
    }

    #[test]
    fn each_tls_failure_says_what_to_do_next() {
        let unknown = driver_message(&DriverError::Tls {
            failure: TlsFailure::UnknownIssuer,
            detail: "unknown issuer".to_owned(),
        });
        assert!(unknown.contains("CA certificate"), "{unknown}");

        let mismatch = driver_message(&DriverError::Tls {
            failure: TlsFailure::NameMismatch,
            detail: "not valid for name".to_owned(),
        });
        assert!(mismatch.contains("server name"), "{mismatch}");
    }

    #[test]
    fn an_unknown_save_outcome_says_to_reload_rather_than_retry() {
        let message = driver_message(&DriverError::CommitOutcomeUnknown {
            token: None,
            source: Box::new(DriverError::ConnectionLost {
                during: tablepro_core::LossPhase::Commit,
            }),
        });

        assert!(message.contains("not known"), "{message}");
        assert!(message.contains("Reload"), "{message}");
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
