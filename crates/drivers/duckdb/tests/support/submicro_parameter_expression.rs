use super::native_connection;
use tablepro_core::Value;

#[tokio::test]
async fn value_contract_submicro_text_parameters_keep_precision_after_explicit_casts() {
    let connection = native_connection().await;
    let time = chrono::NaiveTime::from_hms_nano_opt(12, 34, 56, 123_456_789).unwrap();
    let timestamp =
        chrono::NaiveDateTime::parse_from_str("1969-12-31 23:59:59.123456789", "%Y-%m-%d %H:%M:%S%.f").unwrap();
    let timestamp_tz = chrono::DateTime::parse_from_rfc3339("2026-09-27T12:34:56.123456789+05:30")
        .unwrap()
        .to_utc();
    let time_expression = connection
        .query_params(
            "SELECT CAST(? AS TIME_NS) + INTERVAL '1 nanosecond'",
            &[Value::Time(time)],
        )
        .await;
    assert!(
        matches!(
            time_expression,
            Err(tablepro_core::DriverError::Query { message, .. })
                if message.contains("TIME_NS") && message.contains("INTERVAL")
        ),
        "the native TIME_NS/INTERVAL binder refusal must stay visible"
    );
    let values = [
        Value::Time(time),
        Value::Time(time),
        Value::DateTime(timestamp),
        Value::DateTime(timestamp),
        Value::TimestampTz(timestamp_tz),
        Value::TimestampTz(timestamp_tz),
    ];
    let result = connection
        .query_params(
            "SELECT typeof(CAST(? AS TIME_NS)), CAST(? AS TIME_NS) = TIME_NS '12:34:56.123456789', typeof(CAST(? AS TIMESTAMP_NS)), CAST(? AS TIMESTAMP_NS) = TIMESTAMP_NS '1969-12-31 23:59:59.123456789', typeof(?), CAST(? AS VARCHAR)",
            &values,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("TIME_NS".into()),
            Value::Bool(true),
            Value::Text("TIMESTAMP_NS".into()),
            Value::Bool(true),
            Value::Text("VARCHAR".into()),
            Value::Text("2026-09-27T07:04:56.123456789+00:00".into()),
        ]]
    );

    let arithmetic = connection
        .query_params(
            "SELECT typeof(CAST(? AS TIMESTAMP_NS) + INTERVAL '1 microsecond'), \
             (CAST(? AS TIMESTAMP_NS) + INTERVAL '1 microsecond')::VARCHAR, \
             (CAST(? AS TIMESTAMP_NS) + INTERVAL '1 microsecond')::VARCHAR = \
                 (TIMESTAMP_NS '1969-12-31 23:59:59.123456789' + INTERVAL '1 microsecond')::VARCHAR",
            &[
                Value::DateTime(timestamp),
                Value::DateTime(timestamp),
                Value::DateTime(timestamp),
            ],
        )
        .await
        .unwrap();
    assert_eq!(
        arithmetic.rows,
        vec![vec![
            Value::Text("TIMESTAMP".into()),
            Value::Text("1969-12-31 23:59:59.123458".into()),
            Value::Bool(true),
        ]],
        "TIMESTAMP_NS arithmetic must retain DuckDB's native result type and precision"
    );

    let epoch = connection
        .query_params(
            "SELECT epoch_ns(CAST(? AS TIMESTAMP_NS)), \
             epoch_ns(CAST(? AS TIMESTAMP_NS)) = epoch_ns(TIMESTAMP_NS '1969-12-31 23:59:59.123456789')",
            &[Value::DateTime(timestamp), Value::DateTime(timestamp)],
        )
        .await
        .unwrap();
    assert_eq!(
        epoch.rows,
        vec![vec![Value::Int(-876_543_211), Value::Bool(true)]],
        "epoch_ns must observe all nine digits on a text-bound TIMESTAMP_NS expression"
    );
}

#[tokio::test]
async fn value_contract_duckdb_submicro_parameters_round_trip_into_ns_columns() {
    let connection = native_connection().await;
    connection
        .execute(
            "CREATE TABLE temporal_ns (\
                 id INTEGER PRIMARY KEY, clock TIME_NS, moment TIMESTAMP_NS, sibling TEXT NOT NULL\
             )",
        )
        .await
        .unwrap();

    let initial_time = chrono::NaiveTime::from_hms_nano_opt(12, 34, 56, 123_456_789).unwrap();
    let initial_timestamp =
        chrono::NaiveDateTime::parse_from_str("1969-12-31 23:59:59.123456789", "%Y-%m-%d %H:%M:%S%.f").unwrap();
    let inserted = connection
        .query_params(
            "INSERT INTO temporal_ns VALUES (1, ?, ?, 'keep me') \
             RETURNING id, typeof(clock), clock::VARCHAR, typeof(moment), moment::VARCHAR, sibling",
            &[Value::Time(initial_time), Value::DateTime(initial_timestamp)],
        )
        .await
        .unwrap();
    assert_eq!(
        inserted.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("TIME_NS".into()),
            Value::Text("12:34:56.123456789".into()),
            Value::Text("TIMESTAMP_NS".into()),
            Value::Text("1969-12-31 23:59:59.123456789".into()),
            Value::Text("keep me".into()),
        ]]
    );

    let nulls = connection
        .query_params(
            "INSERT INTO temporal_ns VALUES (2, ?, ?, 'null sibling') \
             RETURNING id, typeof(clock), clock::VARCHAR, typeof(moment), moment::VARCHAR, sibling",
            &[Value::Null, Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        nulls.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("TIME_NS".into()),
            Value::Null,
            Value::Text("TIMESTAMP_NS".into()),
            Value::Null,
            Value::Text("null sibling".into()),
        ]]
    );

    let updated_time = chrono::NaiveTime::from_hms_nano_opt(8, 9, 10, 987_654_321).unwrap();
    let updated_timestamp =
        chrono::NaiveDateTime::parse_from_str("2026-10-06 08:09:10.987654321", "%Y-%m-%d %H:%M:%S%.f").unwrap();
    let updated = connection
        .query_params(
            "UPDATE temporal_ns SET clock = ?, moment = ? WHERE id = 1 \
             RETURNING id, typeof(clock), clock::VARCHAR, typeof(moment), moment::VARCHAR, sibling",
            &[Value::Time(updated_time), Value::DateTime(updated_timestamp)],
        )
        .await
        .unwrap();
    assert_eq!(
        updated.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("TIME_NS".into()),
            Value::Text("08:09:10.987654321".into()),
            Value::Text("TIMESTAMP_NS".into()),
            Value::Text("2026-10-06 08:09:10.987654321".into()),
            Value::Text("keep me".into()),
        ]]
    );

    let rows = connection
        .query(
            "SELECT id, typeof(clock), clock::VARCHAR, typeof(moment), moment::VARCHAR, sibling \
             FROM temporal_ns ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(rows.rows, vec![updated.rows[0].clone(), nulls.rows[0].clone()]);
}
