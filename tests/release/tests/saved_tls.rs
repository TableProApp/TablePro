#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::path::PathBuf;

use secrecy::SecretString;
use tablepro_core::{AuthMode, DriverError, Environment, TlsMode};
use tablepro_release_tests::Fixture;
use tablepro_storage::SavedConnection;
use tablepro_transport::{SshRoute, TransportError, connect_options_for, establish};
use uuid::Uuid;

use drivers_postgres::PgDriver;

fn saved(fixture: &Fixture, mode: TlsMode, root_cert: Option<PathBuf>) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: "Fixture warehouse".into(),
        driver_id: "postgres".into(),
        host: fixture.proxy_host.clone(),
        port: fixture.proxy_port,
        socket_dir: None,
        database: fixture.database.clone(),
        username: fixture.username.clone(),
        use_tls: mode.encrypts(),
        tls_mode: Some(mode),
        tls_root_cert: root_cert,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

async fn connect(fixture: &Fixture, saved: &SavedConnection) -> Result<(), TransportError> {
    connect_with_route(fixture, saved, None).await
}

async fn connect_with_route(
    fixture: &Fixture,
    saved: &SavedConnection,
    route: Option<SshRoute>,
) -> Result<(), TransportError> {
    let mut opts = connect_options_for(saved).await?;
    // The fixture has no Secret Service, so the password that would come from
    // the keyring is supplied here. Everything else, including the certificate
    // authority under test, comes from the saved connection.
    opts.password = SecretString::new(fixture.password.clone().into());
    let (connection, _tunnel) = establish(
        &PgDriver,
        opts,
        route,
        &tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
    )
    .await?;
    connection
        .query("SELECT count(*) FROM release_items")
        .await
        .map_err(TransportError::Driver)?;
    Ok(())
}

fn saved_mtls(fixture: &Fixture, cert_name: Option<&str>, key_name: Option<&str>) -> SavedConnection {
    let materials = fixture.ca_cert.parent().expect("fixture material directory");
    let mut connection = saved(fixture, TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    connection.username = "tablepro_mtls".into();
    connection.tls_client_cert = cert_name.map(|name| materials.join(name));
    connection.tls_client_key = key_name.map(|name| materials.join(name));
    connection
}

fn configure_ssh_mtls_target(fixture: &Fixture, connection: &mut SavedConnection) {
    connection.host = fixture.database_hostname.clone();
    connection.port = fixture.database_port;
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_saved_certificate_authority_verifies_a_privately_issued_certificate() {
    let fixture = Fixture::from_env();
    let connection = saved(&fixture, TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    connect(&fixture, &connection)
        .await
        .expect("a saved certificate authority must verify the fixture certificate");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_saved_connection_without_an_authority_cannot_verify_a_private_certificate() {
    let fixture = Fixture::from_env();
    let connection = saved(&fixture, TlsMode::VerifyFull, None);
    let error = connect(&fixture, &connection)
        .await
        .expect_err("the system trust store does not know the fixture authority");
    assert!(
        matches!(error, TransportError::Driver(DriverError::Tls(_))),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_saved_connection_naming_the_wrong_authority_is_refused() {
    let fixture = Fixture::from_env();
    let connection = saved(&fixture, TlsMode::VerifyFull, Some(fixture.other_ca_cert.clone()));
    let error = connect(&fixture, &connection)
        .await
        .expect_err("an unrelated authority must not verify the fixture certificate");
    assert!(
        matches!(error, TransportError::Driver(DriverError::Tls(_))),
        "expected a TLS error, got {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn an_unverified_mode_ignores_a_saved_authority() {
    let fixture = Fixture::from_env();
    let connection = saved(&fixture, TlsMode::Require, Some(fixture.other_ca_cert.clone()));
    connect(&fixture, &connection)
        .await
        .expect("encrypt-only mode must not fail on an authority it never checks");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn saved_mtls_connection_authenticates_directly_with_client_certificate() {
    let fixture = Fixture::from_env();
    let connection = saved_mtls(&fixture, Some("client.crt"), Some("client.key"));
    connect(&fixture, &connection)
        .await
        .expect("the saved client certificate must authenticate to the mTLS role");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn saved_mtls_connection_authenticates_through_ssh() {
    let fixture = Fixture::from_env();
    let mut connection = saved_mtls(&fixture, Some("client.crt"), Some("client.key"));
    configure_ssh_mtls_target(&fixture, &mut connection);
    connect_with_route(
        &fixture,
        &connection,
        Some(SshRoute::Builtin(vec![fixture.ssh_config()])),
    )
    .await
    .expect("saved client identity and service hostname must survive SSH forwarding");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn server_requiring_client_certificate_rejects_missing_identity() {
    let fixture = Fixture::from_env();
    let connection = saved_mtls(&fixture, None, None);
    assert!(
        connect(&fixture, &connection).await.is_err(),
        "the server must reject an mTLS account without a client certificate"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn server_requiring_client_certificate_rejects_untrusted_identity() {
    let fixture = Fixture::from_env();
    let connection = saved_mtls(&fixture, Some("wrong-client.crt"), Some("wrong-client.key"));
    assert!(
        connect(&fixture, &connection).await.is_err(),
        "the server must reject a client identity signed by another authority"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_rotated_valid_client_certificate_is_used_by_the_saved_connection() {
    let fixture = Fixture::from_env();
    for (cert, key) in [
        ("client.crt", "client.key"),
        ("rotated-client.crt", "rotated-client.key"),
    ] {
        let connection = saved_mtls(&fixture, Some(cert), Some(key));
        connect(&fixture, &connection)
            .await
            .unwrap_or_else(|error| panic!("rotated mTLS identity {cert} should connect: {error}"));
    }
}
