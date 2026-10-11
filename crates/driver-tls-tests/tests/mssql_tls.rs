#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{DatabaseDriver, DriverError, TlsMode};
use tablepro_driver_tls_tests::DriverTlsFixture;

use drivers_mssql::MssqlDriver;

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_connects_with_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MssqlDriver
        .connect(fixture.mssql(TlsMode::VerifyFull, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify full must succeed against the fixture certificate");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_ca_accepts_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MssqlDriver
        .connect(fixture.mssql(TlsMode::VerifyCa, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify ca must succeed against a chain the authority signed");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_rejects_an_ip_endpoint_absent_from_the_certificate() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.mssql(TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    tablepro_driver_tls_tests::assert_endpoint_identity_rejected(&MssqlDriver, options).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_naming_the_wrong_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.mssql(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.mssql(mode, Some(fixture.other_ca_cert.clone()));
        tablepro_driver_tls_tests::assert_certificate_rejected(&MssqlDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn an_encrypt_only_mode_connects_without_an_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MssqlDriver
        .connect(fixture.mssql(TlsMode::Require, None))
        .await
        .expect("encrypt-only must not require an authority it never checks");
    connection.ping().await.expect("an encrypted session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_through_ssh_reaches_the_unpublished_server_and_runs_a_query() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mssql_ssh_tunnel().await;
    let connection = MssqlDriver
        .connect(fixture.mssql_ssh(
            "mssql-ssh.tablepro.test",
            &tunnel,
            TlsMode::VerifyFull,
            Some(fixture.ca_cert.clone()),
        ))
        .await
        .expect("verify full must use the original SQL Server name through SSH");
    let result = connection
        .query("SELECT 1")
        .await
        .expect("native query through verified tunnel");
    assert_eq!(result.rows.len(), 1);
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_through_ssh_rejects_an_untrusted_authority() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mssql_ssh_tunnel().await;
    let accepted = fixture.mssql_ssh(
        "mssql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    let rejected = fixture.mssql_ssh(
        "mssql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.other_ca_cert.clone()),
    );
    tablepro_driver_tls_tests::assert_certificate_rejected(&MssqlDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_through_ssh_rejects_a_wrong_or_local_identity() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mssql_ssh_tunnel().await;
    let accepted = fixture.mssql_ssh(
        "mssql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    let wrong_host = fixture.mssql_ssh(
        "wrong.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    tablepro_driver_tls_tests::assert_certificate_rejected(&MssqlDriver, accepted, wrong_host).await;

    let local_identity = fixture.mssql_ssh("127.0.0.1", &tunnel, TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    let error = MssqlDriver
        .connect(local_identity)
        .await
        .err()
        .expect("verify full must not use the local tunnel address as the TLS identity");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected TLS identity rejection, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn the_server_forces_encryption_and_dropping_tunnel_closes_forward() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mssql_ssh_tunnel().await;
    let local_address = (tunnel.local_host().to_string(), tunnel.local_port());
    let rejected = fixture.mssql_ssh("mssql-ssh.tablepro.test", &tunnel, TlsMode::Disabled, None);
    let connection = MssqlDriver
        .connect(rejected)
        .await
        .expect("the SQL Server fixture forces encrypted connections");
    let encryption = connection
        .query("SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID")
        .await
        .expect("inspect the native connection encryption state");
    assert_eq!(
        encryption.rows[0][0],
        tablepro_core::Value::Text("TRUE".into()),
        "the server must not accept a plaintext SQL Server connection"
    );
    drop(tunnel);
    assert!(
        tokio::net::TcpStream::connect(local_address).await.is_err(),
        "dropping a rejected tunnel must close its local TCP forward"
    );
}
