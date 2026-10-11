#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::path::PathBuf;

use tablepro_core::{ConnectOptions, DatabaseDriver, TlsMode};
use tablepro_driver_tls_tests::{DriverTlsFixture, assert_endpoint_identity_rejected};

use drivers_mysql::MysqlDriver;
use drivers_postgres::PgDriver;

type Options = fn(&DriverTlsFixture, TlsMode, Option<PathBuf>) -> ConnectOptions;

const DRIVERS: [(&dyn DatabaseDriver, Options); 2] = [
    (&PgDriver, DriverTlsFixture::postgres),
    (&MysqlDriver, DriverTlsFixture::mysql),
];

fn fixture_in_system_store() -> DriverTlsFixture {
    let fixture = DriverTlsFixture::from_env();
    let system_store = std::env::var_os("SSL_CERT_FILE").map(PathBuf::from);
    assert_eq!(
        system_store.as_ref(),
        Some(&fixture.ca_cert),
        "run through scripts/test-driver-tls.sh so the system store holds the fixture authority"
    );
    fixture
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn system_store_verifies_when_no_authority_is_named() {
    let fixture = fixture_in_system_store();
    for (driver, options) in DRIVERS {
        let connection = driver
            .connect(options(&fixture, TlsMode::VerifyFull, None))
            .await
            .expect("verify full without a named authority must trust the system store");
        connection.ping().await.expect("ping");
        connection.close().await.expect("close");
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn system_store_verify_ca_checks_the_chain_while_verify_full_checks_the_hostname() {
    let fixture = fixture_in_system_store();
    for (driver, options) in DRIVERS {
        let mut named = options(&fixture, TlsMode::VerifyCa, Some(fixture.ca_cert.clone()));
        named.host = "127.0.0.1".into();
        let connection = driver
            .connect(named)
            .await
            .expect("verify ca with a named authority checks the chain only");
        connection.close().await.expect("close");
        assert_endpoint_identity_rejected(driver, options(&fixture, TlsMode::VerifyFull, None)).await;
    }
}
