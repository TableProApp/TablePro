use std::path::PathBuf;

use tablepro_core::credentials::{SecretError, SecretKind};
use tablepro_core::sql_syntax::script::{OpenConstruct, ScriptDiagnostic};
use tablepro_core::{
    BusyReason, ConfigError, DriverError, ErrorCategory, LossPhase, NetworkEndpoint, ReadOnlyRefusal, ServerCode,
    ServerDiagnostics, SshAlgorithmKind, SshDestinationPart, SshDestinationProblem, SshFailure, SshRuntimeDirProblem,
    StatementOutcome, TimeoutPhase, TlsFailure, TransportError,
};
use tablepro_session::runtime::{TaskFailure, TaskPanic};
use tablepro_session::{ConnectError, OperationError};
use tablepro_storage::KeyringError;

use super::secret::secret_message;
use super::ssh::ssh_failure_message;
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
        (ErrorCategory::Busy, DriverError::Busy(BusyReason::NoFreeConnection)),
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
fn diagnostics_codes_rendered_per_engine() {
    let cases = [
        (ServerCode::SqlState("23505".to_owned()), "SQLSTATE 23505"),
        (
            ServerCode::MySql {
                number: 1062,
                sqlstate: Some("23000".to_owned()),
            },
            "MySQL error 1062",
        ),
        (
            ServerCode::Tds {
                number: 2627,
                state: 1,
                class: 14,
            },
            "SQL Server error 2627",
        ),
        (ServerCode::ClickHouse { code: 60 }, "ClickHouse code 60"),
        (
            ServerCode::Sqlite {
                primary: 19,
                extended: 2067,
            },
            "SQLite error 2067",
        ),
    ];
    for (code, expected) in cases {
        let message = driver_message(&DriverError::reported(ServerDiagnostics::new(Some(code), "refused")));
        assert!(message.contains(expected), "{message}");
    }
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
fn a_refused_login_is_not_called_a_wrong_password() {
    let message = driver_message(&DriverError::LoginRefused(Box::new(ServerDiagnostics::new(
        Some(ServerCode::SqlState("28000".to_owned())),
        "no pg_hba.conf entry for host \"10.0.0.5\", user \"app\", database \"shop\", no encryption",
    ))));

    assert!(!message.contains("wrong"), "{message}");
    assert!(message.contains("no pg_hba.conf entry"), "{message}");
}

#[test]
fn busy_and_editor_busy_messages_differ() {
    assert_ne!(
        driver_message(&DriverError::Busy(BusyReason::NoFreeConnection)),
        driver_message(&DriverError::EditorSessionBusy)
    );
}

#[test]
fn a_locked_file_names_the_lock_not_a_full_server() {
    let locked = driver_message(&DriverError::Busy(BusyReason::FileLocked));
    let full = driver_message(&DriverError::Busy(BusyReason::NoFreeConnection));

    assert_eq!(
        full,
        "The server has no room for another connection right now. Try again shortly."
    );
    assert!(locked.contains("lock on this database file"), "{locked}");
    assert!(!locked.contains("server"), "{locked}");
    assert_ne!(locked, driver_message(&DriverError::EditorSessionBusy));
}

#[test]
fn a_save_whose_commit_met_a_lock_says_why_and_that_nothing_changed() {
    let locked = DriverError::Busy(BusyReason::FileLocked);
    let message = driver_message(&DriverError::RolledBack {
        statement_index: 1,
        source: Box::new(locked.clone()),
    });

    assert!(message.contains(&driver_message(&locked)), "{message}");
    assert!(message.contains("no rows were changed"), "{message}");
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
fn a_timeout_says_the_server_stopped_only_when_it_confirmed() {
    let message = |server_cancelled| {
        driver_message(&DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled,
        })
    };

    assert!(message(true).contains("the server stopped it"), "{}", message(true));
    assert!(!message(false).contains("stopped it"), "{}", message(false));
    assert!(message(false).contains("may still be running"), "{}", message(false));
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
            trust_allowed: true,
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
fn a_failed_negotiation_names_the_server_its_offer_and_the_setting() {
    let cases = [
        (SshAlgorithmKind::KeyExchange, "KexAlgorithms"),
        (SshAlgorithmKind::HostKey, "HostKeyAlgorithms"),
        (SshAlgorithmKind::Cipher, "Ciphers"),
        (SshAlgorithmKind::Mac, "MACs"),
        (SshAlgorithmKind::Compression, "Compression"),
    ];
    let mut messages = std::collections::HashSet::new();
    for (kind, setting) in cases {
        let message = ssh_failure_message(&SshFailure::NoCommonAlgorithm {
            host: "203.0.113.5".to_owned(),
            kind,
            server_offer: vec!["mlkem768x25519-sha256".to_owned(), "sntrup761x25519-sha512".to_owned()],
        });

        assert!(message.contains("203.0.113.5"), "{message}");
        assert!(
            message.contains("mlkem768x25519-sha256, sntrup761x25519-sha512"),
            "{message}"
        );
        assert!(message.contains(setting), "{message}");
        assert!(messages.insert(message), "{kind:?} shares its sentence");
    }
}

#[test]
fn too_many_failed_attempts_names_the_server_and_how_to_limit_the_keys() {
    let message = ssh_failure_message(&SshFailure::TooManyAuthenticationFailures {
        host: "bastion".to_owned(),
    });

    assert!(message.contains("bastion"), "{message}");
    assert!(message.contains("IdentitiesOnly yes"), "{message}");
    assert!(!message.contains("password"), "{message}");
}

/// Under StrictHostKeyChecking yes ssh refuses before it shows the key,
/// so there is no fingerprint to print and no review the user can do.
#[test]
fn an_unknown_key_says_what_the_configuration_allows() {
    let unknown = |sha256_fingerprint: &str, trust_allowed: bool| {
        ssh_failure_message(&SshFailure::HostKeyUnknown {
            host: "[bastion]:2222".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: sha256_fingerprint.to_owned(),
            trust_allowed,
            declined: false,
        })
    };
    let strict = unknown("", false);
    let unseen = unknown("", true);
    let reviewable = unknown("SHA256:abc", true);

    for message in [&strict, &unseen] {
        assert!(message.contains("[bastion]:2222"), "{message}");
        assert!(!message.contains("key )") && !message.contains("(key"), "{message}");
    }
    assert!(strict.contains("known_hosts outside TablePro"), "{strict}");
    assert!(!strict.contains("review"), "{strict}");
    assert!(unseen.contains("review"), "{unseen}");
    assert!(reviewable.contains("(key SHA256:abc)"), "{reviewable}");
    assert!(reviewable.contains("review"), "{reviewable}");
}

#[test]
fn an_invalid_ssh_destination_is_worded_by_the_app() {
    let message = ssh_failure_message(&SshFailure::InvalidDestination {
        problem: SshDestinationProblem::Character {
            part: SshDestinationPart::Host,
            character: '$',
        },
    });

    assert_eq!(
        message,
        "The SSH host or jump host is not valid: the host name contains “$”"
    );
}

#[test]
fn every_ssh_destination_problem_has_its_own_words() {
    let problems = [
        SshDestinationProblem::Empty {
            part: SshDestinationPart::Host,
        },
        SshDestinationProblem::Empty {
            part: SshDestinationPart::User,
        },
        SshDestinationProblem::LeadingDash {
            part: SshDestinationPart::Host,
        },
        SshDestinationProblem::LeadingDash {
            part: SshDestinationPart::User,
        },
        SshDestinationProblem::Whitespace {
            part: SshDestinationPart::Host,
        },
        SshDestinationProblem::Whitespace {
            part: SshDestinationPart::User,
        },
        SshDestinationProblem::Character {
            part: SshDestinationPart::Host,
            character: ';',
        },
        SshDestinationProblem::Character {
            part: SshDestinationPart::User,
            character: ';',
        },
        SshDestinationProblem::PortZero,
        SshDestinationProblem::NotAPort { text: "ssh".to_owned() },
        SshDestinationProblem::UnclosedBracket,
    ];

    let texts: Vec<String> = problems.iter().map(ssh_destination_problem_text).collect();

    for (problem, text) in problems.iter().zip(&texts) {
        assert_ne!(text, &problem.to_string(), "{problem:?} shows its log text");
    }
    assert_eq!(
        texts.iter().collect::<std::collections::HashSet<_>>().len(),
        problems.len(),
        "{texts:?}"
    );
    assert_eq!(texts[7], "the username contains “;”");
    assert_eq!(texts[9], "“ssh” is not a port number");
}

#[test]
fn every_runtime_directory_problem_has_its_own_words() {
    let path = PathBuf::from("/run/user/1000/app/app.tablepro.TablePro/ssh");
    let problems = [
        SshRuntimeDirProblem::OtherOwner,
        SshRuntimeDirProblem::NotADirectory,
        SshRuntimeDirProblem::OpenToOthers { mode: 0o770 },
        SshRuntimeDirProblem::NoDirectoryName,
        SshRuntimeDirProblem::NotAShellWord,
        SshRuntimeDirProblem::Io {
            kind: std::io::ErrorKind::PermissionDenied,
        },
        SshRuntimeDirProblem::Io {
            kind: std::io::ErrorKind::StorageFull,
        },
        SshRuntimeDirProblem::Io {
            kind: std::io::ErrorKind::ReadOnlyFilesystem,
        },
        SshRuntimeDirProblem::Io {
            kind: std::io::ErrorKind::NotADirectory,
        },
        SshRuntimeDirProblem::Io {
            kind: std::io::ErrorKind::Other,
        },
    ];

    let texts: Vec<String> = problems
        .iter()
        .map(|problem| {
            ssh_failure_message(&SshFailure::RuntimeDirUnsafe {
                path: path.clone(),
                problem: *problem,
            })
        })
        .collect();

    for (problem, text) in problems.iter().zip(&texts) {
        assert!(
            !text.contains(&problem.to_string()),
            "{problem:?} shows its log text: {text}"
        );
    }
    assert_eq!(
        texts.iter().collect::<std::collections::HashSet<_>>().len(),
        problems.len(),
        "{texts:?}"
    );
    assert_eq!(
        texts[2],
        "The SSH runtime directory /run/user/1000/app/app.tablepro.TablePro/ssh cannot be used safely: other users can open it (mode 770)"
    );
}

#[test]
fn ssh_exit_status_and_output_are_worded_by_the_app() {
    let protocol = |status: Option<i32>, detail: &str| {
        ssh_failure_message(&SshFailure::Protocol {
            status,
            detail: detail.to_owned(),
        })
    };

    assert_eq!(
        protocol(Some(255), "kex_exchange_identification: read: Connection reset by peer"),
        "ssh exited with status 255: kex_exchange_identification: read: Connection reset by peer"
    );
    assert_eq!(protocol(Some(1), ""), "ssh exited with status 1 and printed nothing.");
    assert_eq!(protocol(None, "Killed"), "ssh printed something unexpected: Killed");
    assert_eq!(protocol(None, ""), "ssh did not answer as TablePro expected.");
    assert_eq!(
        ssh_failure_message(&SshFailure::MasterExited {
            status: Some(255),
            detail: String::new(),
        }),
        "The SSH connection ended."
    );
    assert_eq!(
        ssh_failure_message(&SshFailure::ChannelOpenFailed {
            target: "db:5432".to_owned(),
            detail: String::new(),
        }),
        "The SSH server could not reach db:5432."
    );
    assert_eq!(
        ssh_failure_message(&SshFailure::Internal),
        "TablePro hit an internal error."
    );
}

#[test]
fn an_ssh_that_will_not_start_is_worded_by_the_app() {
    let launch = |kind| {
        ssh_failure_message(&SshFailure::LaunchFailed {
            program: PathBuf::from("/usr/bin/ssh"),
            kind,
        })
    };

    assert_eq!(
        launch(std::io::ErrorKind::PermissionDenied),
        "TablePro is not allowed to run /usr/bin/ssh. Check that it is executable."
    );
    assert_eq!(launch(std::io::ErrorKind::Other), "/usr/bin/ssh could not be started.");
    assert_eq!(
        ssh_failure_message(&SshFailure::ConfigUnreadable {
            path: PathBuf::from("/home/u/.ssh/tablepro_config"),
            kind: std::io::ErrorKind::NotFound,
        }),
        "The SSH configuration file /home/u/.ssh/tablepro_config could not be read."
    );
}

#[test]
fn a_tls_failure_with_no_sentence_of_its_own_hides_the_librarys_text() {
    let library_text = "invalid peer certificate: BadSignature";

    let other = driver_message(&DriverError::Tls {
        failure: TlsFailure::Other,
        detail: library_text.to_owned(),
    });
    let rejected = driver_message(&DriverError::Tls {
        failure: TlsFailure::HandshakeRejected,
        detail: "received fatal alert: HandshakeFailure".to_owned(),
    });

    assert_eq!(other, "The secure connection failed.");
    assert_eq!(rejected, "The server ended the secure handshake.");
}

#[test]
fn a_panic_shows_the_apps_sentence_and_never_the_panic_text() {
    let panic = TaskPanic::from_payload(Box::new("index out of bounds: the len is 0".to_owned()));

    let messages = [
        operation_error_message(&OperationError::Panicked(panic.clone())),
        connect_error_message(&ConnectError::Panicked(panic.clone())),
        task_failure_message(&TaskFailure::Panicked(panic)),
    ];

    for message in messages {
        assert_eq!(message, "TablePro hit an internal error.");
    }
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
        operation_error_message(&OperationError::Driver(DriverError::Busy(BusyReason::NoFreeConnection))),
        driver_message(&DriverError::Busy(BusyReason::NoFreeConnection))
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
            service_message: Some("No such item".to_owned()),
        },
        SecretError::Backend {
            detail: "boom".to_owned(),
            service_message: None,
        },
    ];

    let messages: std::collections::HashSet<String> = errors.iter().map(secret_message).collect();

    assert_eq!(messages.len(), errors.len(), "two errors share a message");
}

#[test]
fn the_portal_message_says_what_to_check() {
    let message = secret_message(&SecretError::PortalUnavailable {
        detail: "org.freedesktop.portal.Secret not found".to_owned(),
    });

    assert!(message.contains("xdg-desktop-portal"), "{message}");
}

#[test]
fn a_backend_error_shows_the_services_words_and_never_oo7s() {
    let answered = secret_message(&SecretError::Backend {
        detail: "DBus error service error org.freedesktop.Secret.Error.NoSuchObject".to_owned(),
        service_message: Some("No such item".to_owned()),
    });
    let silent = secret_message(&SecretError::Backend {
        detail: "DBus error Item/Collection was deleted, can no longer be used".to_owned(),
        service_message: None,
    });

    assert_eq!(answered, "The keyring reported: No such item");
    assert!(!answered.contains("DBus error"), "{answered}");
    assert!(!silent.contains("DBus error"), "{silent}");
}

#[test]
fn oo7s_words_for_a_backend_error_go_to_the_log() {
    let lines = crate::test_support::LogLines::default();
    let _logging = tracing::subscriber::set_default(lines.subscriber(tracing::Level::WARN));

    secret_message(&SecretError::Backend {
        detail: "DBus error Item/Collection was deleted, can no longer be used".to_owned(),
        service_message: None,
    });

    assert!(lines.text().contains("Item/Collection was deleted"), "{}", lines.text());
}

#[test]
fn a_retryable_error_says_to_try_again() {
    assert!(secret_message(&SecretError::Locked).contains("try again"));
}

#[test]
fn unterminated_dollar_quote_diagnostic_names_line() {
    let diagnostic = ScriptDiagnostic::Unterminated {
        construct: OpenConstruct::DollarQuoted,
        start: 10,
    };

    let message = script_diagnostic_message(&diagnostic, 7);

    assert!(message.contains("dollar-quoted"), "{message}");
    assert!(message.contains("line 7"), "{message}");
}

#[test]
fn a_change_a_positional_insert_would_break_names_its_triggers() {
    let one = refusal_text(&tablepro_core::ddl::RefusalReason::InsertedByPosition(vec![
        "audit_copy".to_owned(),
    ]));
    let two = refusal_text(&tablepro_core::ddl::RefusalReason::InsertedByPosition(vec![
        "audit_copy".to_owned(),
        "log_copy".to_owned(),
    ]));

    assert!(one.starts_with("Trigger audit_copy inserts"), "{one}");
    assert!(two.starts_with("Triggers audit_copy, log_copy insert"), "{two}");
}

#[test]
fn a_rebuild_refusal_names_the_dependent_rather_than_a_column() {
    let unreplayable = build_error_text(&tablepro_core::ddl::BuildDdlError::UnreplayableDependent(
        "big_orders".to_owned(),
    ));
    let numbered = refusal_text(&tablepro_core::ddl::RefusalReason::AlwaysNumbered);

    assert!(unreplayable.contains("big_orders"), "{unreplayable}");
    assert!(!unreplayable.contains("Column"), "{unreplayable}");
    assert!(numbered.contains("primary key"), "{numbered}");
}
