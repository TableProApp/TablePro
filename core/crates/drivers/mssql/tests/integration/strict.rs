//! Strict encryption (TDS 8.0): TLS before the first TDS byte. SQL Server
//! on Linux takes it and can require it from 2025; 2022 CU14 on Linux
//! closes a strict login, where 2022 on Windows takes it.

use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::{Connection, DriverError, TlsConfig, TlsFailure, TlsMode, Value, WorkspaceSettings};
use tablepro_test_fixtures::{MssqlFixture, MssqlVersion, PkiFile, ServerVersion, TestPki};

use crate::support::{dial, fixture_options, rows};

/// What `sys.dm_exec_connections` says of the session's own link.
const LINK: &str = "SELECT CONVERT(nvarchar(20), CAST(protocol_version AS varbinary(4)), 1), encrypt_option \
     FROM sys.dm_exec_connections WHERE session_id = @@SPID";
const TDS_8: &str = "0x08000000";

fn selected() -> MssqlVersion {
    MssqlVersion::selected().expect("a known SQL Server release")
}

/// The fixture runs SQL Server on Linux, which speaks TDS 8.0 from 2025.
fn takes_strict(version: MssqlVersion) -> bool {
    version.major() >= 17
}

fn checked(mode: TlsMode, ca_file: PathBuf, server_name: &str) -> TlsConfig {
    TlsConfig {
        mode,
        ca_file: Some(ca_file),
        client_identity: None,
        server_name: Some(server_name.to_owned()),
    }
}

fn strict(fixture: &MssqlFixture, ca: PkiFile, server_name: &str) -> TlsConfig {
    checked(TlsMode::Strict, fixture.pki().path(ca), server_name)
}

async fn open(fixture: &MssqlFixture, tls: TlsConfig) -> Result<Arc<dyn Connection>, DriverError> {
    dial(fixture_options(fixture, tls, WorkspaceSettings::workspace(false))).await
}

fn failure(outcome: &Result<Arc<dyn Connection>, DriverError>) -> Option<TlsFailure> {
    match outcome {
        Err(DriverError::Tls { failure, .. }) => Some(*failure),
        _ => None,
    }
}

async fn protocol(connection: &dyn Connection) -> (String, String) {
    let mut row = rows(connection, LINK).await.remove(0);
    let text = |value: Value| match value {
        Value::Text(text) => text,
        other => format!("not text: {other:?}"),
    };
    let encrypt = text(row.remove(1));
    (text(row.remove(0)), encrypt)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn strict_speaks_tds_8_or_is_refused_by_an_older_server() {
    let fixture = MssqlFixture::start().await.expect("a SQL Server container");
    let tls = strict(&fixture, PkiFile::Ca, TestPki::SERVER_NAMES[1]);

    let outcome = open(&fixture, tls).await;

    if !takes_strict(fixture.version()) {
        assert_eq!(
            failure(&outcome),
            Some(TlsFailure::ServerRefusedStrict),
            "{:?}",
            outcome.err()
        );
        return;
    }
    let connection = outcome.expect("a strict connection");
    assert_eq!(
        protocol(connection.as_ref()).await,
        (TDS_8.to_owned(), "TRUE".to_owned())
    );
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn strict_checks_the_issuer_and_the_name() {
    if !takes_strict(selected()) {
        return;
    }
    let fixture = MssqlFixture::start().await.expect("a SQL Server container");

    let unrelated = open(
        &fixture,
        strict(&fixture, PkiFile::UnrelatedCa, TestPki::SERVER_NAMES[1]),
    )
    .await;
    let wrong_name = open(&fixture, strict(&fixture, PkiFile::Ca, "wrong.tablepro.test")).await;

    assert_eq!(
        failure(&unrelated),
        Some(TlsFailure::UnknownIssuer),
        "{:?}",
        unrelated.err()
    );
    assert_eq!(
        failure(&wrong_name),
        Some(TlsFailure::NameMismatch),
        "{:?}",
        wrong_name.err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn strict_refuses_a_self_signed_certificate_until_it_is_trusted() {
    if !takes_strict(selected()) {
        return;
    }
    let fixture = MssqlFixture::start_self_signed().await.expect("a SQL Server container");
    let untrusted = TlsConfig {
        ca_file: None,
        ..strict(&fixture, PkiFile::Ca, TestPki::SERVER_NAMES[1])
    };

    let refused = open(&fixture, untrusted).await;
    let trusted = open(
        &fixture,
        strict(&fixture, PkiFile::ServerCertificate, TestPki::SERVER_NAMES[1]),
    )
    .await;

    assert_eq!(
        failure(&refused),
        Some(TlsFailure::UnknownIssuer),
        "{:?}",
        refused.err()
    );
    let connection = trusted.expect("the trusted certificate lets the login in");
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_server_that_requires_strict_refuses_tds_7_and_takes_strict() {
    if !takes_strict(selected()) {
        return;
    }
    let fixture = MssqlFixture::start_force_strict()
        .await
        .expect("a SQL Server container");
    let verified = checked(
        TlsMode::VerifyFull,
        fixture.pki().path(PkiFile::Ca),
        TestPki::SERVER_NAMES[1],
    );

    let tds_7 = open(&fixture, verified).await;
    let connection = open(&fixture, strict(&fixture, PkiFile::Ca, TestPki::SERVER_NAMES[1]))
        .await
        .expect("a strict connection");

    assert_eq!(
        failure(&tds_7),
        Some(TlsFailure::ServerRequiresStrict),
        "{:?}",
        tds_7.err()
    );
    assert_eq!(protocol(connection.as_ref()).await.0, TDS_8);
    connection.close().await.expect("a close");
}
