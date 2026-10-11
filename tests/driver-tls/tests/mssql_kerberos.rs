#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;

use drivers_mssql::MssqlDriver;
use tablepro_core::{AuthMode, ConnectOptions, DatabaseDriver, DriverError, TlsConfig, TlsMode, Value};

fn options() -> ConnectOptions {
    tablepro_transport::install_crypto_provider();
    let ca = std::env::var_os("BOOKIE_MSSQL_KRB_CA")
        .map(PathBuf::from)
        .expect("BOOKIE_MSSQL_KRB_CA must point to the fixture CA");
    ConnectOptions {
        host: "mssql.domain1.sink.test".into(),
        port: 1433,
        database: "master".into(),
        username: String::new(),
        auth_mode: AuthMode::Kerberos,
        tls: TlsConfig {
            mode: TlsMode::VerifyFull,
            root_cert: Some(ca),
            ..Default::default()
        },
        ..Default::default()
    }
}

#[tokio::test]
#[ignore = "requires the opt-in SQL Server Kerberos fixture"]
async fn kerberos_ticket_connects_over_verified_tls_and_executes_query() {
    let connection = MssqlDriver
        .connect(options())
        .await
        .expect("a valid AD ticket and SQL Server service keytab must authenticate");
    let result = connection
        .query("SELECT SYSTEM_USER")
        .await
        .expect("the authenticated session must execute a query");
    assert_eq!(result.rows.len(), 1);
    assert!(matches!(&result.rows[0][0], Value::Text(login) if login.eq_ignore_ascii_case("DOMAIN1\\bookiekerb")));
}

#[tokio::test]
#[ignore = "requires the opt-in SQL Server Kerberos fixture"]
async fn kerberos_refuses_an_unregistered_sql_server_spn() {
    let mut options = options();
    // Keep encryption enabled while bypassing certificate-name validation so
    // this assertion measures the KDC/SPN refusal rather than TLS identity.
    options.tls.mode = TlsMode::Require;
    options.service_endpoint = Some(("unregistered.domain1.sink.test".into(), 1433));
    let error = match MssqlDriver.connect(options).await {
        Ok(_) => panic!("an unregistered MSSQLSvc SPN was accepted"),
        Err(error) => error,
    };
    assert!(
        matches!(error, DriverError::IntegratedAuth(_)),
        "expected an integrated-authentication refusal, got {error}"
    );
}
