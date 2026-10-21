#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{MONGO_TAG, MongodbDriver, opts};
use tablepro_core::{DatabaseDriver, DriverError};
use testcontainers::ImageExt;
use testcontainers_modules::mongo::Mongo;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_defined_in_admin_connects_to_another_database_through_the_auth_source() {
    let container = Mongo::default()
        .with_tag(MONGO_TAG)
        .with_env_var("MONGO_INITDB_ROOT_USERNAME", "tablepro")
        .with_env_var("MONGO_INITDB_ROOT_PASSWORD", "correct-password")
        .start()
        .await
        .expect("start authenticated MongoDB");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(27017).await.expect("port");
    let mut options = opts(&host, port, "appdb");
    options.username = "tablepro".into();
    options.password = secrecy::SecretString::new("correct-password".to_string().into());
    options.auth_source = Some("admin".into());

    let connected = tokio::time::timeout(std::time::Duration::from_secs(120), async {
        loop {
            match MongodbDriver.connect(options.clone()).await {
                Ok(connection) => break connection,
                Err(DriverError::ConnectionRefused) => tokio::time::sleep(std::time::Duration::from_millis(100)).await,
                Err(error) => panic!("the admin user must connect through authSource=admin: {error:?}"),
            }
        }
    })
    .await
    .expect("MongoDB must become ready within 120 seconds");
    connected.query(r#"db.things.find({})"#).await.unwrap();

    options.auth_source = None;
    let error = MongodbDriver
        .connect(options)
        .await
        .err()
        .expect("authenticating against appdb must fail");
    assert!(matches!(error, DriverError::AuthFailed), "{error:?}");
}
