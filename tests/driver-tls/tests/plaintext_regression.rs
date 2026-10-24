#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! Enabling TLS on a driver must not cost it the ability to speak plaintext.
//! These run against servers that offer no encryption at all.

use tablepro_core::{DatabaseDriver, TlsMode};
use tablepro_driver_tls_tests::DriverTlsFixture;

use drivers_clickhouse::ClickhouseDriver;
use drivers_mongodb::MongodbDriver;
use drivers_mssql::MssqlDriver;
use drivers_mysql::MysqlDriver;
use drivers_redis::RedisDriver;

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn mongodb_still_connects_to_a_server_without_encryption() {
    let fixture = DriverTlsFixture::from_env();
    let connection = MongodbDriver
        .connect(fixture.mongo_plaintext())
        .await
        .expect("a disabled TLS mode must connect to a plaintext server");
    let tables = connection.list_tables().await.expect("list collections");
    assert!(
        tables.iter().any(|table| table.name == "release_items"),
        "the seeded collection must be visible: {tables:?}"
    );
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn redis_still_connects_to_a_server_without_encryption() {
    let fixture = DriverTlsFixture::from_env();
    let connection = RedisDriver
        .connect(fixture.redis_plaintext())
        .await
        .expect("a disabled TLS mode must connect to a plaintext server");
    connection.ping().await.expect("a plaintext session must be usable");
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mongodb_client_will_not_fall_back_to_plaintext() {
    let fixture = DriverTlsFixture::from_env();
    let accepted = fixture.mongo_plaintext();
    let mut rejected = accepted.clone();
    rejected.tls.mode = TlsMode::VerifyFull;
    tablepro_driver_tls_tests::assert_connection_rejected(&MongodbDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_redis_client_will_not_fall_back_to_plaintext() {
    let fixture = DriverTlsFixture::from_env();
    let accepted = fixture.redis_plaintext();
    let mut rejected = accepted.clone();
    rejected.tls.mode = TlsMode::VerifyFull;
    tablepro_driver_tls_tests::assert_connection_rejected(&RedisDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mysql_client_will_not_fall_back_to_plaintext() {
    let fixture = DriverTlsFixture::from_env();
    let accepted = fixture.mysql_plaintext();
    let mut rejected = accepted.clone();
    rejected.tls.mode = TlsMode::VerifyFull;
    tablepro_driver_tls_tests::assert_connection_rejected(&MysqlDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_clickhouse_client_will_not_fall_back_to_plaintext() {
    let fixture = DriverTlsFixture::from_env();
    let accepted = fixture.clickhouse_plaintext();
    let mut rejected = accepted.clone();
    rejected.tls.mode = TlsMode::VerifyFull;
    tablepro_driver_tls_tests::assert_connection_rejected(&ClickhouseDriver, accepted, rejected).await;
}

#[tokio::test]
#[ignore = "requires the driver tls fixture"]
async fn a_verifying_mssql_client_will_not_fall_back_to_plaintext() {
    let fixture = DriverTlsFixture::from_env();
    let accepted = fixture.mssql_plaintext();
    let mut rejected = accepted.clone();
    rejected.tls.mode = TlsMode::VerifyFull;
    tablepro_driver_tls_tests::assert_connection_rejected(&MssqlDriver, accepted, rejected).await;
}
