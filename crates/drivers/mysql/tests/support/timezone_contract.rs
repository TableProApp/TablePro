#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use chrono::{TimeZone, Utc};
use tablepro_core::{ConnectOptions, OperationControl, Value};

use crate::{connect, start_mariadb, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn session_non_utc_time_zone_refuses_mysql_timestamp_instant() {
    let (_container, options) = start_mysql().await;
    assert_non_utc_timestamp_contract(options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_session_non_utc_time_zone_refuses_timestamp_instant() {
    let (_container, options) = start_mariadb().await;
    assert_non_utc_timestamp_contract(options, "MariaDB").await;
}

async fn assert_non_utc_timestamp_contract(options: ConnectOptions, engine: &str) {
    let conn = connect(options).await;
    conn.execute("CREATE TABLE timezone_source (id INT PRIMARY KEY, instant TIMESTAMP(6) NOT NULL)")
        .await
        .unwrap();

    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled("SET time_zone = '+05:45'", &[], &control)
        .await
        .unwrap();
    session
        .query_params_controlled(
            "INSERT INTO timezone_source VALUES (1, '2024-01-02 03:04:05.123456')",
            &[],
            &control,
        )
        .await
        .unwrap();
    let result = session
        .query_params_controlled(
            "SELECT instant, CAST(instant AS CHAR) AS session_local, \
             CAST(UNIX_TIMESTAMP(instant) * 1000000 AS SIGNED) AS epoch_micros \
             FROM timezone_source WHERE id = 1",
            &[],
            &control,
        )
        .await
        .unwrap();

    let expected_instant =
        Utc.with_ymd_and_hms(2024, 1, 1, 21, 19, 5).unwrap() + chrono::Duration::microseconds(123_456);
    assert_eq!(
        result.rows.len(),
        1,
        "{engine}: exactly one keyed timestamp must be returned"
    );
    assert_eq!(
        result.columns.len(),
        3,
        "{engine}: timestamp, local text, and epoch metadata must be present"
    );
    assert_eq!(
        result.columns[0].data_type, "TIMESTAMP",
        "{engine}: preserve native temporal type metadata"
    );
    assert_eq!(
        result.rows[0][1],
        Value::Text("2024-01-02 03:04:05.123456".into()),
        "{engine}: native text must retain the session-local timestamp"
    );
    assert_eq!(
        result.rows[0][2],
        Value::Int(expected_instant.timestamp_micros()),
        "{engine}: native epoch must identify the same UTC instant"
    );
    assert_eq!(
        result.rows[0][0],
        Value::Undecodable("TIMESTAMP (session time zone is not UTC)".into()),
        "{engine}: a local timestamp must not be mislabeled as a UTC instant"
    );

    conn.execute("SET time_zone = '+05:45'").await.unwrap();
    let pooled_result = conn
        .query("SELECT instant FROM timezone_source WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(
        pooled_result.rows[0][0],
        Value::TimestampTz(expected_instant),
        "{engine}: the pooled connection remains UTC"
    );

    let mut tx = conn.begin().await.unwrap();
    tx.execute("SET time_zone = '+05:45'").await.unwrap();
    let transaction_result = tx
        .query("SELECT instant FROM timezone_source WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(
        transaction_result.rows[0][0],
        Value::Undecodable("TIMESTAMP (session time zone is not UTC)".into()),
        "{engine}: the transaction must report its changed session zone"
    );
    tx.rollback().await.unwrap();
}
