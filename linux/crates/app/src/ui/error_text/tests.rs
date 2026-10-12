use std::path::PathBuf;

use tablepro_core::credentials::{SecretError, SecretKind};
use tablepro_core::{
    ConfigError, DriverError, ErrorCategory, LossPhase, NetworkEndpoint, ReadOnlyRefusal, ServerCode,
    ServerDiagnostics, SshFailure, StatementOutcome, TimeoutPhase, TlsFailure, TransportError,
};
use tablepro_session::runtime::TaskPanic;
use tablepro_session::{ConnectError, OperationError};
use tablepro_storage::KeyringError;

use super::secret::secret_message;
use super::*;

/// One error per category, so a category without a branch shows up as
/// an empty or shared sentence.
fn one_per_category() -> Vec<(ErrorCategory, DriverError)> {
    let endpoint = NetworkEndpoint::new("db.internal", 5432).expect("an endpoint");
    vec![
        (
            ErrorCategory::Configuration,
            DriverError::Config(ConfigError::DatabaseRequired),
        ),
        (
            ErrorCategory::Network,
            DriverError::Transport(TransportError::Refused { endpoint }),
        ),
        (
            ErrorCategory::Tls,
            DriverError::Tls {
                failure: TlsFailure::Expired,
                detail: "expired".to_owned(),
            },
        ),
        (ErrorCategory::Authentication, DriverError::auth(None)),
        (
            ErrorCategory::ReadOnly,
            DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard),
        ),
        (ErrorCategory::Server, DriverError::server("syntax error")),
        (ErrorCategory::Interrupted, DriverError::Cancelled),
        (
            ErrorCategory::Timeout,
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            },
        ),
        (
            ErrorCategory::ConnectionLost,
            DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
        ),
        (
            ErrorCategory::WriteOutcome,
            DriverError::RowGuardFailed {
                statement_index: 0,
                expected: 1,
                actual: 0,
            },
        ),
        (
            ErrorCategory::File,
            DriverError::FileNotFound {
                path: PathBuf::from("/srv/app.db"),
            },
        ),
        (ErrorCategory::Busy, DriverError::Busy),
        (ErrorCategory::Internal, DriverError::Protocol("bad frame".to_owned())),
    ]
}

#[test]
fn every_category_has_a_message() {
    let cases = one_per_category();
    let messages: std::collections::HashSet<String> = cases
        .iter()
        .map(|(category, error)| {
            assert_eq!(error.category(), *category, "{error:?}");
            let message = driver_message(error);
            assert!(!message.trim().is_empty(), "{category:?} has no message");
            message
        })
        .collect();

    assert_eq!(messages.len(), cases.len(), "two categories share a message");
}

#[test]
fn server_message_includes_code_detail_hint() {
    let diagnostics = ServerDiagnostics {
        detail: Some("Key (email)=(a@b.c) already exists.".to_owned()),
        hint: Some("Pick another email.".to_owned()),
        ..ServerDiagnostics::new(Some(ServerCode::SqlState("23505".to_owned())), "duplicate key")
    };

    let message = driver_message(&DriverError::reported(diagnostics));

    assert!(message.contains("23505"), "{message}");
    assert!(message.contains("duplicate key"), "{message}");
    assert!(message.contains("already exists"), "{message}");
    assert!(message.contains("Pick another email."), "{message}");

    let numbered = driver_message(&DriverError::reported(ServerDiagnostics::new(
        Some(ServerCode::Tds {
            number: 208,
            state: 1,
            class: 16,
        }),
        "Invalid object name 'users'.",
    )));
    assert!(numbered.contains("208"), "{numbered}");

    let bare = driver_message(&DriverError::server("syntax error"));
    assert!(!bare.contains("SQLSTATE"), "{bare}");
    assert!(bare.contains("syntax error"), "{bare}");
}

#[test]
fn tls_unknown_issuer_suggests_ca() {
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
fn auth_message_has_no_secret() {
    let message = driver_message(&DriverError::auth(Some(ServerDiagnostics::new(
        None,
        "password authentication failed for user \"app\"",
    ))));

    assert!(message.contains("wrong"), "{message}");
    assert!(message.contains("password authentication failed"), "{message}");
    assert!(!message.contains("hunter2"));
}

#[test]
fn busy_and_editor_busy_messages_differ() {
    assert_ne!(
        driver_message(&DriverError::Busy),
        driver_message(&DriverError::EditorSessionBusy)
    );
}

#[test]
fn file_not_found_names_path() {
    let message = driver_message(&DriverError::FileNotFound {
        path: PathBuf::from("/srv/app.db"),
    });

    assert!(message.contains("/srv/app.db"), "{message}");
}

#[test]
fn timeout_phase_login_vs_statement_differ() {
    let timeout = |phase| {
        driver_message(&DriverError::Timeout {
            phase,
            server_cancelled: false,
        })
    };

    assert_ne!(timeout(TimeoutPhase::Login), timeout(TimeoutPhase::Statement));
    assert_eq!(
        driver_message(&DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect
        })),
        timeout(TimeoutPhase::Connect),
        "a transport timeout reads like the driver's own"
    );
}

#[test]
fn partially_applied_and_commit_unknown_never_claim_rollback() {
    let lost = Box::new(DriverError::ConnectionLost {
        during: LossPhase::Commit,
    });
    let unknown = driver_message(&DriverError::CommitOutcomeUnknown {
        token: None,
        source: lost.clone(),
    });
    let partial = driver_message(&DriverError::PartiallyApplied {
        applied: 2,
        statement_index: 2,
        failed_outcome: StatementOutcome::Failed,
        source: lost,
    });

    for message in [&unknown, &partial] {
        assert!(!message.contains("rolled back"), "{message}");
        assert!(!message.contains("no rows were changed"), "{message}");
        assert!(message.contains("Reload"), "{message}");
    }
}

#[test]
fn a_refused_connection_names_the_server_it_tried() {
    let endpoint = NetworkEndpoint::new("db.internal", 5432).expect("an endpoint");

    let message = driver_message(&DriverError::Transport(TransportError::Refused { endpoint }));

    assert!(message.contains("db.internal:5432"), "{message}");
}

#[test]
fn integrated_auth_names_the_remedy_and_keeps_the_gssapi_detail() {
    let message = driver_message(&DriverError::IntegratedAuth("No Kerberos credentials available".into()));
    assert!(message.contains("No Kerberos credentials available"));
    assert!(message.contains("kinit"));
    assert!(message.contains("SPN"));
}

#[test]
fn ssh_failures_say_what_to_change() {
    let changed = driver_message(&DriverError::Transport(TransportError::Ssh(
        SshFailure::HostKeyChanged {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: "SHA256:new".to_owned(),
            known_hosts: PathBuf::from("/home/u/.ssh/known_hosts"),
            line: 7,
        },
    )));
    assert!(changed.contains("known_hosts"), "{changed}");
    assert!(changed.contains('7'), "{changed}");

    let missing = ssh_failure_message(&SshFailure::OpenSshClientMissing {
        program: PathBuf::from("ssh"),
    });
    assert!(missing.contains("openssh-client"), "{missing}");

    let declined = ssh_failure_message(&SshFailure::HostKeyUnknown {
        host: "bastion".to_owned(),
        algorithm: "ED25519".to_owned(),
        sha256_fingerprint: "SHA256:abc".to_owned(),
        trust_allowed: true,
        declined: true,
    });
    assert!(declined.contains("not trusted"), "{declined}");
}

#[test]
fn connect_error_text_covers_every_variant() {
    let errors = [
        ConnectError::Driver(DriverError::auth(None)),
        ConnectError::Keyring(KeyringError::SecretNotStored {
            kind: SecretKind::DatabasePassword,
        }),
        ConnectError::Keyring(KeyringError::Secret {
            kind: SecretKind::DatabasePassword,
            error: SecretError::Locked,
        }),
        ConnectError::UnknownDriver("oracle".to_owned()),
        ConnectError::Cancelled,
        ConnectError::Panicked(TaskPanic::from_payload(Box::new("boom"))),
    ];

    let messages: std::collections::HashSet<String> = errors.iter().map(connect_error_message).collect();

    assert_eq!(messages.len(), errors.len(), "two connect errors share a message");
    assert!(connect_error_message(&errors[3]).contains("oracle"));
}

#[test]
fn operation_errors_cancelled_and_closed_differ() {
    assert_ne!(
        operation_error_message(&OperationError::Cancelled),
        operation_error_message(&OperationError::Closed)
    );
    assert_eq!(
        operation_error_message(&OperationError::Driver(DriverError::Busy)),
        driver_message(&DriverError::Busy)
    );
}

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
