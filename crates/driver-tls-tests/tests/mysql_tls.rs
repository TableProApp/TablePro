#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{DatabaseDriver, TlsMode};
use tablepro_driver_tls_tests::DriverTlsFixture;

use drivers_mysql::MysqlDriver;

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_connects_with_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MysqlDriver
        .connect(fixture.mysql(TlsMode::VerifyFull, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify full must succeed against the fixture certificate");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_ca_accepts_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MysqlDriver
        .connect(fixture.mysql(TlsMode::VerifyCa, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify ca must succeed against a chain the authority signed");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_plaintext_mode_is_refused_by_a_tls_only_server() {
    let fixture = DriverTlsFixture::from_env();
    let result = MysqlDriver.connect(fixture.mysql(TlsMode::Disabled, None)).await;
    assert!(
        result.is_err(),
        "a server that requires secure transport must refuse an unencrypted client"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_rejects_an_ip_endpoint_absent_from_the_certificate() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.mysql(TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    tablepro_driver_tls_tests::assert_endpoint_identity_rejected(&MysqlDriver, options).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_without_an_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.mysql(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.mysql(mode, None);
        tablepro_driver_tls_tests::assert_certificate_rejected(&MysqlDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_naming_the_wrong_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.mysql(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.mysql(mode, Some(fixture.other_ca_cert.clone()));
        tablepro_driver_tls_tests::assert_certificate_rejected(&MysqlDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn an_encrypt_only_mode_connects_without_an_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MysqlDriver
        .connect(fixture.mysql(TlsMode::Require, None))
        .await
        .expect("encrypt-only must not require an authority it never checks");
    connection.ping().await.expect("an encrypted session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_through_ssh_reaches_the_unpublished_server_and_runs_a_query() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mysql_ssh_tunnel().await;
    let connection = MysqlDriver
        .connect(fixture.mysql_ssh(
            "mysql-ssh.tablepro.test",
            &tunnel,
            TlsMode::VerifyFull,
            Some(fixture.ca_cert.clone()),
        ))
        .await
        .expect("verify full must use the original MySQL service name through SSH");
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
    let tunnel = fixture.open_mysql_ssh_tunnel().await;
    let accepted = fixture.mysql_ssh(
        "mysql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    let rejected = fixture.mysql_ssh(
        "mysql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.other_ca_cert.clone()),
    );
    tablepro_driver_tls_tests::assert_certificate_rejected(&MysqlDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_through_ssh_rejects_a_wrong_or_local_identity() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mysql_ssh_tunnel().await;
    let accepted = fixture.mysql_ssh(
        "mysql-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    let wrong_host = fixture.mysql_ssh(
        "wrong.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    tablepro_driver_tls_tests::assert_certificate_rejected(&MysqlDriver, accepted.clone(), wrong_host).await;

    let local_identity = fixture.mysql_ssh("127.0.0.1", &tunnel, TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    let error = MysqlDriver
        .connect(local_identity)
        .await
        .err()
        .expect("verify full must not use the local tunnel address as the TLS identity");
    assert!(
        matches!(error, tablepro_core::DriverError::Tls(_)),
        "expected TLS identity rejection, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_tls_rejection_does_not_fall_back_to_plaintext_and_dropping_tunnel_cleans_up() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mysql_ssh_tunnel().await;
    let socket_dir = tunnel.socket_dir().expect("socket tunnel directory").to_path_buf();
    let rejected = fixture.mysql_ssh("mysql-ssh.tablepro.test", &tunnel, TlsMode::Disabled, None);
    assert!(
        MysqlDriver.connect(rejected).await.is_err(),
        "TLS-only MySQL must reject plaintext over the SSH forward"
    );
    drop(tunnel);
    assert!(
        !socket_dir.exists(),
        "dropping a rejected tunnel must remove its local socket directory"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_server_requiring_a_client_certificate_accepts_a_valid_identity() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.mysql_mtls(
        TlsMode::VerifyFull,
        Some(fixture.client_cert.clone()),
        Some(fixture.client_key.clone()),
    );
    let connection = MysqlDriver
        .connect(options)
        .await
        .expect("a valid client certificate must authenticate to the mTLS account");
    connection.ping().await.expect("mTLS session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_server_requiring_a_client_certificate_rejects_a_missing_identity() {
    let fixture = DriverTlsFixture::from_env();
    let result = MysqlDriver
        .connect(fixture.mysql_mtls(TlsMode::VerifyFull, None, None))
        .await;
    assert!(
        result.is_err(),
        "the mTLS account must reject a client without a certificate"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_server_requiring_a_client_certificate_rejects_an_untrusted_identity() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.mysql_mtls(
        TlsMode::VerifyFull,
        Some(fixture.wrong_client_cert.clone()),
        Some(fixture.wrong_client_key.clone()),
    );
    let result = MysqlDriver.connect(options).await;
    assert!(
        result.is_err(),
        "the server must reject a client identity signed by another CA"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_rotated_valid_client_identity_connects() {
    let fixture = DriverTlsFixture::from_env();
    for (cert, key) in [
        (&fixture.client_cert, &fixture.client_key),
        (&fixture.rotated_client_cert, &fixture.rotated_client_key),
    ] {
        let connection = MysqlDriver
            .connect(fixture.mysql_mtls(TlsMode::VerifyFull, Some(cert.clone()), Some(key.clone())))
            .await
            .expect("a valid rotated client identity must authenticate");
        connection.ping().await.expect("mTLS session must be usable");
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_server_requiring_a_client_certificate_accepts_the_identity_through_ssh() {
    let fixture = DriverTlsFixture::from_env();
    let tunnel = fixture.open_mysql_mtls_ssh_tunnel().await;
    let options = fixture.mysql_mtls_ssh(
        "mysql-mtls-ssh.tablepro.test",
        &tunnel,
        TlsMode::VerifyFull,
        Some(fixture.client_cert.clone()),
        Some(fixture.client_key.clone()),
    );
    let connection = MysqlDriver
        .connect(options)
        .await
        .expect("client identity and original hostname must survive SSH forwarding");
    connection
        .query("SELECT 1")
        .await
        .expect("native query through mTLS SSH tunnel");
}
