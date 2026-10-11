#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{DatabaseDriver, TlsMode};
use tablepro_driver_tls_tests::DriverTlsFixture;

use drivers_clickhouse::ClickhouseDriver;

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_connects_with_the_fixture_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = ClickhouseDriver
        .connect(fixture.clickhouse(TlsMode::VerifyFull, Some(fixture.ca_cert.clone())))
        .await
        .expect("verify full must succeed against the fixture certificate");
    connection.ping().await.expect("a verified session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn verify_full_rejects_an_ip_endpoint_absent_from_the_certificate() {
    let fixture = DriverTlsFixture::from_env();
    let options = fixture.clickhouse(TlsMode::VerifyFull, Some(fixture.ca_cert.clone()));
    tablepro_driver_tls_tests::assert_endpoint_identity_rejected(&ClickhouseDriver, options).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_without_an_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.clickhouse(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.clickhouse(mode, None);
        tablepro_driver_tls_tests::assert_certificate_rejected(&ClickhouseDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mode_naming_the_wrong_authority_is_refused() {
    let fixture = DriverTlsFixture::from_env();
    for mode in [TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let accepted = fixture.clickhouse(mode, Some(fixture.ca_cert.clone()));
        let rejected = fixture.clickhouse(mode, Some(fixture.other_ca_cert.clone()));
        tablepro_driver_tls_tests::assert_certificate_rejected(&ClickhouseDriver, accepted, rejected).await;
    }
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn an_encrypt_only_mode_connects_without_an_authority() {
    let fixture = DriverTlsFixture::from_env();
    let connection = ClickhouseDriver
        .connect(fixture.clickhouse(TlsMode::Require, None))
        .await
        .expect("encrypt-only must not require an authority it never checks");
    connection.ping().await.expect("an encrypted session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_plaintext_mode_does_not_reach_the_https_port() {
    let fixture = DriverTlsFixture::from_env();
    let result = ClickhouseDriver
        .connect(fixture.clickhouse(TlsMode::Disabled, None))
        .await;
    assert!(
        result.is_err(),
        "an unencrypted request must not be accepted by the https port"
    );
}
