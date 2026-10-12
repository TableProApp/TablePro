#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use secrecy::SecretString;
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError};

use crate::start_pg;

async fn refused(options: ConnectOptions) -> DriverError {
    match drivers_postgres::PgDriver.connect(options).await {
        Ok(_) => panic!("the server accepted a login it should have refused"),
        Err(error) => error,
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_wrong_password_or_unknown_role_is_an_authentication_failure() {
    let (_server, options) = start_pg().await;
    let wrong_password = refused(ConnectOptions {
        password: SecretString::new("not the password".to_string().into()),
        ..options.clone()
    })
    .await;
    assert!(matches!(wrong_password, DriverError::AuthFailed), "{wrong_password:?}");

    let unknown_role = refused(ConnectOptions {
        username: "nobody_here".into(),
        ..options
    })
    .await;
    assert!(matches!(unknown_role, DriverError::AuthFailed), "{unknown_role:?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_missing_database_is_a_query_error_with_its_sqlstate() {
    let (_server, options) = start_pg().await;
    let error = refused(ConnectOptions {
        database: "no_such_database".into(),
        ..options
    })
    .await;
    assert!(
        matches!(&error, DriverError::Query { sqlstate: Some(state), .. } if state == "3D000"),
        "{error:?}"
    );
}
