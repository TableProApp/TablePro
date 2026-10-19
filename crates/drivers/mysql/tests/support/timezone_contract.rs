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

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_repeated_dst_hour_instants_remain_distinct_keys() {
    let (_container, options) = start_mysql().await;
    assert_repeated_dst_hour_contract(options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_repeated_dst_hour_instants_remain_distinct_keys() {
    let (_container, options) = start_mariadb().await;
    assert_repeated_dst_hour_contract(options, "MariaDB").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_temporal_defaults_use_the_utc_session_and_preserve_sql_mode() {
    let (_container, options) = start_mysql().await;
    assert_temporal_default_contract(options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_temporal_defaults_use_the_utc_session_and_preserve_sql_mode() {
    let (_container, options) = start_mariadb().await;
    assert_temporal_default_contract(options, "MariaDB").await;
}

async fn assert_repeated_dst_hour_contract(options: ConnectOptions, engine: &str) {
    let connection = connect(options).await;
    let timezone = connection
        .query(
            "SELECT @@session.time_zone, \
             CONVERT_TZ('2024-11-03 05:30:00', '+00:00', 'America/New_York'), \
             CONVERT_TZ('2024-11-03 06:30:00', '+00:00', 'America/New_York'), \
             CONVERT_TZ('2024-01-15 12:00:00', '+00:00', '+05:45')",
        )
        .await
        .unwrap();
    assert_eq!(timezone.rows.len(), 1, "{engine}: timezone oracle row");
    assert_eq!(
        timezone.rows[0][0],
        Value::Text("+00:00".into()),
        "{engine}: UTC session"
    );
    let repeated_hour = &timezone.rows[0][1];
    assert_eq!(
        repeated_hour, &timezone.rows[0][2],
        "{engine}: both DST instants share local wall time"
    );
    assert_eq!(
        timezone.rows[0][3],
        Value::DateTime(chrono::NaiveDateTime::parse_from_str("2024-01-15 17:45:00", "%Y-%m-%d %H:%M:%S").unwrap()),
        "{engine}: fixed-offset native conversion"
    );
    let first = Utc.with_ymd_and_hms(2024, 11, 3, 5, 30, 0).unwrap();
    let second = Utc.with_ymd_and_hms(2024, 11, 3, 6, 30, 0).unwrap();
    connection
        .execute("CREATE TABLE repeated_hour_keys (instant TIMESTAMP(6) PRIMARY KEY, label VARCHAR(16) NOT NULL)")
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    for (instant, label) in [(first, "first"), (second, "second")] {
        connection
            .execute_params_controlled(
                "INSERT INTO repeated_hour_keys VALUES (?, ?)",
                &[Value::TimestampTz(instant), Value::Text(label.into())],
                &control,
            )
            .await
            .unwrap();
    }
    let rows = connection
        .query(
            "SELECT label, CONVERT_TZ(instant, '+00:00', 'America/New_York'), \
             CAST(UNIX_TIMESTAMP(instant) * 1000000 AS SIGNED) \
             FROM repeated_hour_keys ORDER BY instant",
        )
        .await
        .unwrap();
    assert_eq!(
        rows.rows.len(),
        2,
        "{engine}: distinct instants remain distinct primary keys"
    );
    assert_eq!(rows.rows[0][0], Value::Text("first".into()));
    assert_eq!(rows.rows[1][0], Value::Text("second".into()));
    assert_eq!(rows.rows[0][1], *repeated_hour);
    assert_eq!(rows.rows[1][1], *repeated_hour);
    assert_eq!(rows.rows[0][2], Value::Int(first.timestamp_micros()));
    assert_eq!(rows.rows[1][2], Value::Int(second.timestamp_micros()));
    connection
        .execute_params_controlled(
            "UPDATE repeated_hour_keys SET label = ? WHERE instant = ?",
            &[Value::Text("updated".into()), Value::TimestampTz(first)],
            &control,
        )
        .await
        .unwrap();
    let labels = connection
        .query("SELECT label FROM repeated_hour_keys ORDER BY instant")
        .await
        .unwrap();
    assert_eq!(
        labels.rows,
        vec![vec![Value::Text("updated".into())], vec![Value::Text("second".into())]],
        "{engine}: a repeated-hour key updates only its intended instant"
    );
}

async fn assert_temporal_default_contract(options: ConnectOptions, engine: &str) {
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE temporal_defaults (\
             id INT PRIMARY KEY, \
             created TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6), \
             local_created DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6), \
             changed TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6), \
             label VARCHAR(16) NOT NULL DEFAULT 'before')",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO temporal_defaults (id) VALUES (1)")
        .await
        .unwrap();
    let initial = connection
        .query(
            "SELECT @@session.time_zone, @@session.sql_mode, created, local_created, changed, label \
             FROM temporal_defaults WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(initial.rows.len(), 1, "{engine}: default row");
    assert_eq!(initial.rows[0][0], Value::Text("+00:00".into()), "{engine}: UTC writes");
    let sql_mode = initial.rows[0][1].clone();
    let created = match &initial.rows[0][2] {
        Value::TimestampTz(value) => *value,
        other => panic!("{engine}: unexpected TIMESTAMP default {other:?}"),
    };
    let local_created = match &initial.rows[0][3] {
        Value::DateTime(value) => *value,
        other => panic!("{engine}: unexpected DATETIME default {other:?}"),
    };
    let changed = match &initial.rows[0][4] {
        Value::TimestampTz(value) => *value,
        other => panic!("{engine}: unexpected ON UPDATE default {other:?}"),
    };
    assert_eq!(
        created.naive_utc(),
        local_created,
        "{engine}: UTC TIMESTAMP and DATETIME defaults"
    );
    assert_eq!(changed, created, "{engine}: ON UPDATE value starts at the insert time");
    assert_eq!(
        initial.rows[0][5],
        Value::Text("before".into()),
        "{engine}: literal default"
    );

    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    connection
        .execute("UPDATE temporal_defaults SET label = 'after' WHERE id = 1")
        .await
        .unwrap();
    let after = connection
        .query(
            "SELECT @@session.time_zone, @@session.sql_mode, created, changed, label \
             FROM temporal_defaults WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(after.rows.len(), 1, "{engine}: updated row");
    assert_eq!(
        after.rows[0][0],
        Value::Text("+00:00".into()),
        "{engine}: UTC session remains set"
    );
    assert_eq!(
        after.rows[0][1], sql_mode,
        "{engine}: generated writes retain server SQL mode"
    );
    assert_eq!(
        after.rows[0][2],
        Value::TimestampTz(created),
        "{engine}: insert default is stable"
    );
    let updated = match &after.rows[0][3] {
        Value::TimestampTz(value) => *value,
        other => panic!("{engine}: unexpected ON UPDATE value {other:?}"),
    };
    assert!(updated > changed, "{engine}: ON UPDATE advances the instant");
    assert_eq!(after.rows[0][4], Value::Text("after".into()), "{engine}: keyed update");
}
