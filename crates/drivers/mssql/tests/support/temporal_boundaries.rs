use super::{connect, start_mssql};
use chrono::{NaiveDate, NaiveDateTime};
use tablepro_core::{OperationControl, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_supported_temporal_calendar_edges_match_native_text_and_bind_exactly() {
    let (_container, options) = start_mssql().await;
    let connection = connect(options).await;
    let boundary_sql = "SELECT CAST('0001-01-01' AS date), CONVERT(varchar(10), CAST('0001-01-01' AS date), 23), \
             CAST('9999-12-31' AS date), CONVERT(varchar(10), CAST('9999-12-31' AS date), 23), \
             CAST('0001-01-01T00:00:00.0000001' AS datetime2(7)), \
             CONVERT(varchar(27), CAST('0001-01-01T00:00:00.0000001' AS datetime2(7)), 126), \
             CAST('9999-12-31T23:59:59.9999999' AS datetime2(7)), \
             CONVERT(varchar(27), CAST('9999-12-31T23:59:59.9999999' AS datetime2(7)), 126), \
             CAST('00:00:00.0000001' AS time(7)), \
             CONVERT(varchar(16), CAST('00:00:00.0000001' AS time(7)), 126), \
             CAST('23:59:59.9999999' AS time(7)), \
             CONVERT(varchar(16), CAST('23:59:59.9999999' AS time(7)), 126)";
    let boundaries = connection
        .query(boundary_sql)
        .await
        .expect("query native temporal boundaries");
    assert_eq!(boundaries.rows.len(), 1);
    let mut session = connection.open_session().await.expect("open SQL Server session");
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let session_boundaries = session
        .query_params_controlled(boundary_sql, &[], &control)
        .await
        .expect("query temporal boundaries through the session batch path");
    assert_eq!(session_boundaries.columns, boundaries.columns);
    assert_eq!(session_boundaries.rows, boundaries.rows);
    session.close().await.expect("close SQL Server session");
    assert_eq!(
        boundaries.rows[0],
        vec![
            Value::Date(date(1, 1, 1)),
            Value::Text("0001-01-01".into()),
            Value::Date(date(9999, 12, 31)),
            Value::Text("9999-12-31".into()),
            Value::DateTime(datetime(1, 1, 1, 0, 0, 0, 100)),
            Value::Text("0001-01-01T00:00:00.0000001".into()),
            Value::DateTime(datetime(9999, 12, 31, 23, 59, 59, 999_999_900)),
            Value::Text("9999-12-31T23:59:59.9999999".into()),
            Value::Time(time(0, 0, 0, 100)),
            Value::Text("00:00:00.0000001".into()),
            Value::Time(time(23, 59, 59, 999_999_900)),
            Value::Text("23:59:59.9999999".into()),
        ]
    );

    connection
        .execute(
            "CREATE TABLE date_time_edges (id int PRIMARY KEY, day date NOT NULL, precise datetime2(7) NOT NULL, clock time(7) NOT NULL); \
             CREATE TABLE date_time_edges_copy (id int PRIMARY KEY, day date NOT NULL, precise datetime2(7) NOT NULL, clock time(7) NOT NULL)",
        )
        .await
        .expect("create source and copy tables");
    let params = vec![
        Value::Int(1),
        Value::Date(date(1, 1, 1)),
        Value::DateTime(datetime(1, 1, 1, 0, 0, 0, 100)),
        Value::Time(time(0, 0, 0, 100)),
        Value::Int(2),
        Value::Date(date(9999, 12, 31)),
        Value::DateTime(datetime(9999, 12, 31, 23, 59, 59, 999_999_900)),
        Value::Time(time(23, 59, 59, 999_999_900)),
    ];
    connection
        .execute_params(
            "INSERT INTO date_time_edges VALUES (@P1, @P2, @P3, @P4), (@P5, @P6, @P7, @P8)",
            &params,
        )
        .await
        .expect("bind both DATE and DATETIME2(7) boundaries");

    let rows = connection
        .query(
            "SELECT id, day, precise, clock, CONVERT(varchar(10), day, 23), \
             CONVERT(varchar(27), precise, 126), CONVERT(varchar(16), clock, 126) \
             FROM date_time_edges ORDER BY id",
        )
        .await
        .expect("read bound temporal values");
    assert_eq!(rows.rows.len(), 2);
    assert_eq!(rows.rows[0][1], Value::Date(date(1, 1, 1)));
    assert_eq!(rows.rows[0][2], Value::DateTime(datetime(1, 1, 1, 0, 0, 0, 100)));
    assert_eq!(rows.rows[0][3], Value::Time(time(0, 0, 0, 100)));
    assert_eq!(rows.rows[0][4], Value::Text("0001-01-01".into()));
    assert_eq!(rows.rows[0][5], Value::Text("0001-01-01T00:00:00.0000001".into()));
    assert_eq!(rows.rows[0][6], Value::Text("00:00:00.0000001".into()));
    assert_eq!(rows.rows[1][1], Value::Date(date(9999, 12, 31)));
    assert_eq!(
        rows.rows[1][2],
        Value::DateTime(datetime(9999, 12, 31, 23, 59, 59, 999_999_900))
    );
    assert_eq!(rows.rows[1][3], Value::Time(time(23, 59, 59, 999_999_900)));
    assert_eq!(rows.rows[1][4], Value::Text("9999-12-31".into()));
    assert_eq!(rows.rows[1][5], Value::Text("9999-12-31T23:59:59.9999999".into()));
    assert_eq!(rows.rows[1][6], Value::Text("23:59:59.9999999".into()));

    let columns = connection.fetch_columns(None, "date_time_edges_copy").await.unwrap();
    for row in &rows.rows {
        let insert = tablepro_core::sql_literal::build_insert_literal(
            "mssql",
            None,
            "date_time_edges_copy",
            &columns,
            &row[..4],
        )
        .expect("calendar edge remains exactly representable as SQL literals");
        connection.execute(&insert).await.expect("re-import literal");
    }
    let copied = connection
        .query(
            "SELECT id, day, precise, clock, CONVERT(varchar(10), day, 23), \
             CONVERT(varchar(27), precise, 126), CONVERT(varchar(16), clock, 126) \
             FROM date_time_edges_copy ORDER BY id",
        )
        .await
        .expect("read SQL-literal re-import");
    assert_eq!(copied.rows, rows.rows);
}

fn date(year: i32, month: u32, day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(year, month, day).expect("valid SQL Server calendar edge")
}

fn time(hour: u32, minute: u32, second: u32, nanos: u32) -> chrono::NaiveTime {
    chrono::NaiveTime::from_hms_nano_opt(hour, minute, second, nanos).expect("valid SQL Server time edge")
}

fn datetime(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32, nanos: u32) -> NaiveDateTime {
    date(year, month, day)
        .and_hms_nano_opt(hour, minute, second, nanos)
        .expect("valid SQL Server datetime2 edge")
}
