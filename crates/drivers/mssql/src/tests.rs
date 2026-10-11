use super::*;

#[tokio::test]
async fn connect_deadline_drops_the_in_flight_connect_future() {
    use std::future::pending;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct DropSignal(Arc<AtomicBool>);

    impl Drop for DropSignal {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let dropped = Arc::new(AtomicBool::new(false));
    let signal = DropSignal(Arc::clone(&dropped));
    let connect = async move {
        let _signal = signal;
        pending::<Result<(), DriverError>>().await
    };

    let result = connect_with_deadline(std::time::Duration::from_millis(1), connect).await;

    assert!(matches!(result, Err(DriverError::ConnectionRefused)));
    assert!(dropped.load(Ordering::SeqCst));
}

#[test]
fn terminal_session_kill_is_disconnected_but_sql_errors_are_preserved() {
    assert!(matches!(map_server_error(596, "killed", 1), DriverError::Disconnected));
    assert!(matches!(
        map_server_error(18456, "login failed", 1),
        DriverError::AuthFailed
    ));
    assert!(matches!(
        map_server_error(245, "conversion failed", 2),
        DriverError::Query { message, sqlstate, .. }
            if message == "conversion failed" && sqlstate.as_deref() == Some("2")
    ));
}

#[test]
fn undecodable_cell_cannot_be_bound_as_null() {
    assert!(matches!(
        boxed_params(&[Value::Undecodable("geometry".into())]),
        Err(DriverError::Unsupported(_))
    ));
}

#[test]
fn structure_metadata_declarations_match_the_connection_impl() {
    let d = MssqlDriver;
    let source = include_str!("lib.rs");
    assert!(d.supports_index_metadata());
    assert!(d.supports_foreign_key_metadata());
    assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
    assert!(source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
}

#[test]
fn driver_metadata() {
    let d = MssqlDriver;
    assert_eq!(d.id(), "mssql");
    assert_eq!(d.display_name(), "SQL Server");
    assert_eq!(d.default_port(), 1433);
    assert_eq!(d.default_database(), "master");
    assert_eq!(d.default_username(), "sa");
    assert!(!d.is_file_based());
    assert_eq!(d.supports_integrated_auth(), cfg!(feature = "kerberos"));
}

fn direct_options() -> ConnectOptions {
    ConnectOptions {
        host: "sql.corp.example".into(),
        port: 1433,
        database: "sales".into(),
        ..Default::default()
    }
}

#[test]
fn direct_connection_uses_service_identity_as_dial_endpoint() {
    let target = build_target(&direct_options()).unwrap();

    assert_eq!(target.config.get_addr(), "sql.corp.example:1433");
    assert_eq!(
        (target.dial_host.as_str(), target.dial_port),
        ("sql.corp.example", 1433)
    );
}

#[test]
fn tunnel_connection_uses_service_identity_for_tls_and_spn() {
    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port: 54321,
        service_endpoint: Some(("sql.corp.example".into(), 1433)),
        ..direct_options()
    };
    let target = build_target(&options).unwrap();

    assert_eq!(target.config.get_addr(), "sql.corp.example:1433");
    assert_eq!((target.dial_host.as_str(), target.dial_port), ("127.0.0.1", 54321));
}

#[test]
fn local_server_shorthand_dials_localhost() {
    let options = ConnectOptions {
        host: ".".into(),
        ..direct_options()
    };
    let target = build_target(&options).unwrap();

    assert_eq!(target.config.get_addr(), "localhost:1433");
    assert_eq!(target.dial_host, "localhost");
}

#[test]
fn verify_ca_with_a_named_authority_does_not_panic_on_conflicting_trust_settings() {
    // tiberius panics if trust_cert() and trust_cert_ca() are both
    // called on the same Config -- build_target must route a saved
    // root_cert into trust_cert_ca() only, never trust_cert(), for
    // VerifyCa/VerifyFull.
    let options = ConnectOptions {
        tls: tablepro_core::TlsConfig {
            mode: tablepro_core::TlsMode::VerifyCa,
            root_cert: Some(std::path::PathBuf::from("/etc/ssl/private-ca.pem")),
            ..Default::default()
        },
        ..direct_options()
    };
    let _ = build_target(&options).unwrap();
}

#[test]
fn verify_full_without_a_named_authority_does_not_panic() {
    let options = ConnectOptions {
        tls: tablepro_core::TlsConfig {
            mode: tablepro_core::TlsMode::VerifyFull,
            ..Default::default()
        },
        ..direct_options()
    };
    let _ = build_target(&options).unwrap();
}

#[test]
fn kerberos_connect_attempts_do_not_accumulate() {
    let first = KerberosAttempt::acquire().unwrap();
    assert!(KerberosAttempt::acquire().is_err());
    drop(first);
    assert!(KerberosAttempt::acquire().is_ok());
}

#[test]
#[cfg(feature = "kerberos")]
fn kerberos_uses_integrated_authentication() {
    let options = ConnectOptions {
        auth_mode: AuthMode::Kerberos,
        username: "ignored".into(),
        ..direct_options()
    };

    assert_eq!(auth_method(&options).unwrap(), AuthMethod::Integrated);
    assert_eq!(auth_method(&direct_options()).unwrap(), AuthMethod::sql_server("", ""));
}

#[test]
#[cfg(feature = "kerberos")]
fn gssapi_errors_are_classified_as_integrated_authentication_failures() {
    let error = map_tiberius_error(tiberius::error::Error::Gssapi("ticket expired".into()));

    assert!(matches!(error, DriverError::IntegratedAuth(detail) if detail == "ticket expired"));
}

#[test]
#[cfg(not(feature = "kerberos"))]
fn disabled_kerberos_is_rejected_before_connecting() {
    let options = ConnectOptions {
        auth_mode: AuthMode::Kerberos,
        ..direct_options()
    };
    assert!(!MssqlDriver.supports_integrated_auth());
    assert!(matches!(build_target(&options), Err(DriverError::IntegratedAuth(_))));
}

#[test]
fn quote_ident_brackets_and_escapes() {
    assert_eq!(quote_ident("users"), "[users]");
    assert_eq!(quote_ident("My Table"), "[My Table]");
    assert_eq!(quote_ident("weird]name"), "[weird]]name]");
}

#[test]
fn qualified_uses_bracket_quoting() {
    assert_eq!(qualified(Some("dbo"), "users"), "[dbo].[users]");
    assert_eq!(qualified(None, "users"), "[users]");
}

#[test]
fn format_type_lengths_and_precision() {
    assert_eq!(format_mssql_type("int", 4, 10, 0), "int");
    assert_eq!(format_mssql_type("varchar", 255, 0, 0), "varchar(255)");
    assert_eq!(format_mssql_type("varchar", -1, 0, 0), "varchar(max)");
    // nvarchar max_length is in bytes: 510 bytes -> 255 chars.
    assert_eq!(format_mssql_type("nvarchar", 510, 0, 0), "nvarchar(255)");
    assert_eq!(format_mssql_type("nvarchar", -1, 0, 0), "nvarchar(max)");
    assert_eq!(format_mssql_type("decimal", 9, 18, 2), "decimal(18,2)");
    assert_eq!(format_mssql_type("datetimeoffset", 10, 0, 3), "datetimeoffset(3)");
}

#[test]
fn normalize_default_peels_parens_and_keeps_literal_quotes() {
    assert_eq!(normalize_mssql_default("((0))"), "0");
    assert_eq!(normalize_mssql_default("('pending')"), "'pending'");
    assert_eq!(normalize_mssql_default("('')"), "''");
    assert_eq!(normalize_mssql_default("(NULL)"), "NULL");
    assert_eq!(normalize_mssql_default("(getdate())"), "getdate()");
    assert_eq!(normalize_mssql_default("(N'x')"), "N'x'");
    assert_eq!(normalize_mssql_default("('it''s')"), "'it''s'");
}

#[test]
fn normalize_default_leaves_unbalanced_alone() {
    // A leading `(` that doesn't wrap the whole expression must not be
    // stripped, or the value would be corrupted.
    assert_eq!(normalize_mssql_default("(a)+(b)"), "(a)+(b)");
}

#[test]
fn referential_actions_map_to_keywords() {
    assert_eq!(map_referential_action("CASCADE"), Some("CASCADE".to_string()));
    assert_eq!(map_referential_action("SET_NULL"), Some("SET NULL".to_string()));
    assert_eq!(map_referential_action("SET_DEFAULT"), Some("SET DEFAULT".to_string()));
    assert_eq!(map_referential_action("NO_ACTION"), None);
}

#[tokio::test(start_paused = true)]
async fn retire_wakes_the_fault_sink_and_leaves_the_outcome_unknown() {
    let fault = Arc::new(Notify::new());
    let connection = MssqlConnection::unconnected();
    connection.attach_fault_notify(Arc::clone(&fault));

    let notified = fault.notified();
    tokio::pin!(notified);
    assert!(!notified.as_mut().enable(), "the sink must be idle until retire");

    let control = OperationControl::with_timeout(std::time::Duration::from_secs(1));
    let result = connection
        .run_abandonable(
            async {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                Err::<(), DriverError>(DriverError::Disconnected)
            },
            &control,
        )
        .await;

    assert!(
        matches!(
            result,
            Err(DriverError::OperationOutcomeUnknown { source })
                if matches!(source.as_ref(), DriverError::Disconnected)
        ),
        "an in-flight call must stay unknown when cancellation is not confirmed"
    );
    assert!(!connection.usable.load(Ordering::Acquire));

    let woke = tokio::time::timeout(std::time::Duration::from_millis(1), notified).await;
    assert!(woke.is_ok(), "retire must wake the fault sink");
}
