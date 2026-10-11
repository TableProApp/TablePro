#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{DatabaseDriver, DriverError, TlsMode};
use tablepro_release_tests::Fixture;

use drivers_postgres::PgDriver;

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_succeeds_against_the_certificate_hostname() {
    let fixture = Fixture::from_env();
    let connection = PgDriver
        .connect(fixture.direct_options(&fixture.proxy_host, TlsMode::VerifyFull, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify full must succeed for a hostname in the certificate");
    connection.ping().await.expect("verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_rejects_a_hostname_outside_the_certificate() {
    let fixture = Fixture::from_env();
    let error = PgDriver
        .connect(fixture.direct_options("127.0.0.1", TlsMode::VerifyFull, Some(fixture.ca_cert.clone())))
        .await
        .err()
        .expect("verify full must reject an address that the certificate does not name");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_rejects_an_unknown_certificate_authority() {
    let fixture = Fixture::from_env();
    let error = PgDriver
        .connect(fixture.direct_options(
            &fixture.proxy_host,
            TlsMode::VerifyFull,
            Some(fixture.other_ca_cert.clone()),
        ))
        .await
        .err()
        .expect("verify full must reject a chain signed by an unrelated authority");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_ca_rejects_an_unknown_certificate_authority() {
    let fixture = Fixture::from_env();
    let error = PgDriver
        .connect(fixture.direct_options(
            &fixture.proxy_host,
            TlsMode::VerifyCa,
            Some(fixture.other_ca_cert.clone()),
        ))
        .await
        .err()
        .expect("verify ca must reject a chain signed by an unrelated authority");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn ssh_tunnel_reaches_a_database_with_no_published_port() {
    let fixture = Fixture::from_env();
    let tunnel = fixture.open_tunnel().await;
    let connection = PgDriver
        .connect(fixture.tunneled_options(&tunnel, TlsMode::Require, None))
        .await
        .expect("encrypted session through the bastion");
    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("query");
    assert_eq!(result.rows.len(), 1);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_through_ssh_uses_the_original_database_hostname() {
    let fixture = Fixture::from_env();
    let socket_name = PgDriver
        .forwarded_socket_name(fixture.database_port)
        .expect("postgres reports a forwarded socket name");
    let tunnel = fixture.open_socket_tunnel(&socket_name).await;
    let options = fixture.socket_options(
        &tunnel,
        &fixture.database_hostname,
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );
    assert_eq!(
        options.service_address(),
        (fixture.database_hostname.as_str(), fixture.database_port)
    );

    let connection = PgDriver
        .connect(options)
        .await
        .expect("verify full through ssh must succeed against the original hostname");
    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("query through the verified tunnel");
    assert_eq!(result.rows.len(), 1);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_through_ssh_rejects_a_hostname_outside_the_certificate() {
    let fixture = Fixture::from_env();
    let socket_name = PgDriver
        .forwarded_socket_name(fixture.database_port)
        .expect("postgres reports a forwarded socket name");
    let tunnel = fixture.open_socket_tunnel(&socket_name).await;
    let options = fixture.socket_options(
        &tunnel,
        "wrong.tablepro.test",
        TlsMode::VerifyFull,
        Some(fixture.ca_cert.clone()),
    );

    let error = PgDriver
        .connect(options)
        .await
        .err()
        .expect("a service identity the certificate does not name must be rejected");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn verify_full_over_a_tcp_tunnel_never_downgrades_to_the_local_dial_address() {
    let fixture = Fixture::from_env();
    let tunnel = fixture.open_tunnel().await;
    let options = fixture.tunneled_options(&tunnel, TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    assert_eq!(
        options.service_address(),
        (fixture.database_hostname.as_str(), fixture.database_port)
    );

    let outcome = PgDriver.connect(options).await;

    let error = outcome
        .err()
        .expect("verify full through ssh must not succeed against the local dial address");
    assert!(
        matches!(error, DriverError::Tls(_)),
        "expected a TLS error, got {error}"
    );
}
