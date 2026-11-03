//! Integrated login through SSPI against a SQL Server on this Windows
//! machine, which `tests/windows/sql-server.ps1` installs and gives a
//! self-signed certificate, exported to the PEM file
//! `TABLEPRO_TEST_MSSQL_WINDOWS_CA` names. The machine is in no domain,
//! so SSPI signs in with NTLM.

use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::{Connection, Credentials, DriverError, TlsConfig, TlsFailure, TlsMode, Value, WorkspaceSettings};
use tablepro_test_support::conformance::test_liveness;

use crate::support::{dial, direct, options_over, rows};

const HOST: &str = "localhost";
const PORT: u16 = 1433;
const CA: &str = "TABLEPRO_TEST_MSSQL_WINDOWS_CA";
const LINK: &str = "SELECT c.auth_scheme, CONVERT(nvarchar(20), CAST(c.protocol_version AS varbinary(4)), 1), \
     c.encrypt_option, SUSER_SNAME() FROM sys.dm_exec_connections c WHERE c.session_id = @@SPID";

struct Link {
    auth_scheme: String,
    protocol: String,
    encrypted: String,
    login: String,
}

fn checked(mode: TlsMode) -> TlsConfig {
    let ca = std::env::var_os(CA).expect("the server certificate's PEM file");
    TlsConfig {
        mode,
        ca_file: Some(PathBuf::from(ca)),
        client_identity: None,
        server_name: None,
    }
}

async fn open(tls: TlsConfig) -> Result<Arc<dyn Connection>, DriverError> {
    let liveness = test_liveness();
    dial(options_over(
        direct(HOST, PORT, &liveness),
        Credentials::Integrated,
        tls,
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await
}

async fn link(connection: &dyn Connection) -> Link {
    let row = rows(connection, LINK).await.remove(0);
    let text = |value: &Value| match value {
        Value::Text(text) => text.clone(),
        other => format!("not text: {other:?}"),
    };
    Link {
        auth_scheme: text(&row[0]),
        protocol: text(&row[1]),
        encrypted: text(&row[2]),
        login: text(&row[3]),
    }
}

async fn signs_in(mode: TlsMode, protocol: &str) {
    let connection = open(checked(mode)).await.expect("an integrated login");

    let link = link(connection.as_ref()).await;

    assert!(
        matches!(link.auth_scheme.as_str(), "NTLM" | "KERBEROS"),
        "{}",
        link.auth_scheme
    );
    assert_eq!(link.protocol, protocol);
    assert_eq!(link.encrypted, "TRUE");
    assert!(link.login.contains('\\'), "a Windows account, not {}", link.login);
    connection.close().await.expect("a close");
}

/// Run before the server is set to Force Strict Encryption.
mod sspi {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn integrated_login_over_tds_7() {
        signs_in(TlsMode::VerifyFull, "0x74000004").await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn integrated_login_over_strict_tls() {
        signs_in(TlsMode::Strict, "0x08000000").await;
    }
}

/// Run after the server is set to Force Strict Encryption.
mod force_strict {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn tds_7_is_refused_and_strict_signs_in() {
        let refused = open(checked(TlsMode::VerifyFull)).await;

        assert!(
            matches!(
                refused,
                Err(DriverError::Tls {
                    failure: TlsFailure::ServerRequiresStrict,
                    ..
                })
            ),
            "{:?}",
            refused.err()
        );
        signs_in(TlsMode::Strict, "0x08000000").await;
    }
}
