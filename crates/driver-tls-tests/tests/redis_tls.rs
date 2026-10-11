#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{DatabaseDriver, DriverError, TlsMode};
use tablepro_driver_tls_tests::DriverTlsFixture;

use drivers_redis::RedisDriver;

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_connects_with_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.redis(TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    let connection = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        loop {
            match RedisDriver.connect(options.clone()).await {
                Ok(connection) => break connection,
                Err(DriverError::ConnectionRefused) => {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                Err(error) => panic!("verified Redis TLS connection failed: {error:?}"),
            }
        }
    })
    .await
    .expect("Redis TLS fixture must accept connections within 30 seconds");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_plaintext_mode_is_refused_by_a_tls_only_server() {
    let fixture = DriverTlsFixture::from_env();
    let result = RedisDriver.connect(fixture.redis(TlsMode::Disabled, None)).await;
    assert!(
        result.is_err(),
        "a server that requires TLS must refuse an unencrypted client"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verifying_modes_reject_an_ip_endpoint_absent_from_the_certificate() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let options = fixture.redis(mode, Some(fixture.ca_cert.clone()));
        tablepro_driver_tls_tests::assert_endpoint_identity_rejected(&RedisDriver, options).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_without_an_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.redis(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.redis(mode, None);
        tablepro_driver_tls_tests::assert_certificate_rejected(&RedisDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_naming_the_wrong_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.redis(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.redis(mode, Some(fixture.other_ca_cert.clone()));
        tablepro_driver_tls_tests::assert_certificate_rejected(&RedisDriver, accepted, rejected).await;
    }
}
