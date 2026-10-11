#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ConnectOptions, DriverError, OperationControl, Value};

use crate::connect;

async fn assert_unsigned_subtraction_mode(options: ConnectOptions, engine: &str) {
    let connection = connect(options).await;
    let mut session = connection.open_session().await.expect("open pinned session");
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));

    session
        .query_params_controlled("SET SESSION sql_mode = ''", &[], &control)
        .await
        .expect("disable unsigned subtraction mode");
    let error = session
        .query_params_controlled("SELECT CAST(0 AS UNSIGNED) - 1", &[], &control)
        .await
        .expect_err("unsigned underflow must fail when the mode is off");
    assert!(
        matches!(error, DriverError::Query { sqlstate: Some(ref state), .. } if state == "22003"),
        "{engine}: unsigned underflow should retain native SQLSTATE 22003, got {error:?}"
    );

    session
        .query_params_controlled("SET SESSION sql_mode = 'NO_UNSIGNED_SUBTRACTION'", &[], &control)
        .await
        .expect("enable signed subtraction mode");
    let mode = session
        .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &control)
        .await
        .expect("read active session mode");
    assert_eq!(
        mode.rows,
        vec![vec![Value::Text("NO_UNSIGNED_SUBTRACTION".into())]],
        "{engine}"
    );

    let result = session
        .query_params_controlled(
            "SELECT CAST(0 AS UNSIGNED) - 1, CAST(42 AS UNSIGNED) - 1, \
             CAST(9223372036854775807 AS UNSIGNED) - 0",
            &[],
            &control,
        )
        .await
        .expect("signed subtraction results");
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        if engine == "MariaDB" {
            vec!["INT", "INT", "BIGINT"]
        } else {
            vec!["BIGINT", "BIGINT", "BIGINT"]
        },
        "{engine}: subtraction result metadata must match the server's signed expression types"
    );
    assert_eq!(
        result.rows,
        vec![vec![Value::Int(-1), Value::Int(41), Value::Int(i64::MAX)]],
        "{engine}: signed subtraction must preserve negative and boundary results"
    );

    let overflow = session
        .query_params_controlled("SELECT CAST(9223372036854775808 AS UNSIGNED) - 0", &[], &control)
        .await
        .expect_err("signed result must reject values above BIGINT's maximum");
    assert!(
        matches!(overflow, DriverError::Query { sqlstate: Some(ref state), .. } if state == "22003"),
        "{engine}: signed overflow should retain native SQLSTATE 22003, got {overflow:?}"
    );

    session.close().await.expect("close pinned session");
    connection.close().await.expect("close connection");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_unsigned_subtraction_obeys_session_mode_and_signed_boundaries() {
    let (_container, options) = crate::start_mysql().await;
    assert_unsigned_subtraction_mode(options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_unsigned_subtraction_obeys_session_mode_and_signed_boundaries() {
    let (_container, options) = crate::start_mariadb().await;
    assert_unsigned_subtraction_mode(options, "MariaDB").await;
}
