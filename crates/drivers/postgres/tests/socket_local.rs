#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! PostgreSQL Unix-socket integration smoke.
//!
//! Run through `scripts/test-postgres-socket.sh`; the harness exposes a
//! real PostgreSQL socket directory from a disposable container.

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, Value};
use tokio_util::sync::CancellationToken;

fn options() -> ConnectOptions {
    let directory = std::env::var("TABLEPRO_PG_SOCKET_DIR").expect("TABLEPRO_PG_SOCKET_DIR is set by the harness");
    ConnectOptions {
        host: "localhost".into(),
        port: std::env::var("TABLEPRO_PG_SOCKET_PORT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5432),
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new(String::new().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        local_socket_dir: Some(directory.into()),
        ..Default::default()
    }
}

#[tokio::test]
#[ignore = "requires scripts/test-postgres-socket.sh"]
async fn socket_query_write_cancel_and_reconnect() {
    let options = options();
    let connection = PgDriver
        .connect(options.clone())
        .await
        .expect("connect over Unix socket");
    let result = connection.query("SELECT 41 + 1").await.expect("query");
    assert_eq!(result.rows, vec![vec![Value::Int(42)]]);

    connection
        .execute("CREATE TABLE tablepro_socket_smoke (id int primary key)")
        .await
        .expect("governed-write driver primitive");
    assert_eq!(
        connection
            .execute("INSERT INTO tablepro_socket_smoke VALUES (1)")
            .await
            .expect("insert")
            .rows_affected,
        1
    );

    let token = CancellationToken::new();
    token.cancel();
    let error = connection
        .query_controlled("SELECT pg_sleep(30)", &OperationControl::new(token, None))
        .await
        .expect_err("pre-cancelled query must not run");
    assert!(matches!(error, tablepro_core::DriverError::Cancelled));
    connection.close().await.expect("close");

    let reconnected = PgDriver.connect(options).await.expect("reconnect over Unix socket");
    assert_eq!(
        reconnected.query("SELECT 1").await.expect("query after reconnect").rows,
        vec![vec![Value::Int(1)]]
    );
}
