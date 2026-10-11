use super::{col, parse_input_for_driver};
use chrono::Timelike;
use tablepro_core::Value;

#[test]
fn value_contract_duckdb_extended_calendar_values_parse_as_exact_text() {
    let date = col("DATE", false);
    assert_eq!(
        parse_input_for_driver("1000000-02-29", Some(&date), "duckdb").unwrap(),
        Value::Text("1000000-02-29".into())
    );
    assert!(parse_input_for_driver("1000001-02-29", Some(&date), "duckdb").is_err());
    assert_eq!(
        parse_input_for_driver("0001-01-01 (BC)", Some(&date), "duckdb").unwrap(),
        Value::Text("0001-01-01 (BC)".into())
    );

    let timestamp = col("TIMESTAMP", false);
    assert_eq!(
        parse_input_for_driver("280000-02-29 12:34:56.123456", Some(&timestamp), "duckdb").unwrap(),
        Value::Text("280000-02-29 12:34:56.123456".into())
    );
    assert!(parse_input_for_driver("280001-02-29 12:34:56", Some(&timestamp), "duckdb").is_err());
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_extended_calendar_grid_edits_preserve_native_values() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE extended_dates (id INTEGER PRIMARY KEY, day DATE, moment TIMESTAMP)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO extended_dates VALUES (1, DATE '1000000-02-29', TIMESTAMP '280000-02-29 12:34:56.123456')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "extended_dates").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let day_index = columns.iter().position(|column| column.name == "day").unwrap();
    let moment_index = columns.iter().position(|column| column.name == "moment").unwrap();
    let before = connection.query("SELECT * FROM extended_dates").await.unwrap();
    assert_eq!(before.rows[0][day_index], Value::Text("1000000-02-29".into()));
    assert_eq!(
        before.rows[0][moment_index],
        Value::Text("280000-02-29 12:34:56.123456".into())
    );
    let edits = [
        (
            day_index,
            parse_input_for_driver("1000001-03-01", Some(&columns[day_index]), "duckdb").unwrap(),
        ),
        (
            moment_index,
            parse_input_for_driver("280001-03-01 01:02:03.654321", Some(&columns[moment_index]), "duckdb").unwrap(),
        ),
    ];
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "extended_dates",
        &columns,
        &edits,
        &[before.rows[0][id_index].clone()],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    assert_eq!(
        connection
            .query("SELECT CAST(day AS VARCHAR), CAST(moment AS VARCHAR) FROM extended_dates")
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("1000001-03-01".into()),
            Value::Text("280001-03-01 01:02:03.654321".into())
        ]]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_extended_timestamptz_grid_edits_preserve_instants() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection.execute("SET TimeZone = 'UTC'").await.unwrap();
    connection
        .execute("CREATE TABLE extended_zoned (id INTEGER PRIMARY KEY, moment TIMESTAMPTZ)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO extended_zoned VALUES \
             (1, TIMESTAMPTZ '280000-02-29 12:34:56.123456+00:00')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "extended_zoned").await.unwrap();
    let moment_index = columns.iter().position(|column| column.name == "moment").unwrap();
    let before = connection.query("SELECT * FROM extended_zoned").await.unwrap();
    assert_eq!(
        before.rows[0][moment_index],
        Value::Text("280000-02-29 12:34:56.123456+00".into())
    );
    let edited = parse_input_for_driver(
        "280001-03-01T01:02:03.654321+05:30",
        Some(&columns[moment_index]),
        "duckdb",
    )
    .unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "extended_zoned",
        &columns,
        &[(moment_index, edited)],
        &[before.rows[0][0].clone()],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    assert_eq!(
        connection
            .query("SELECT epoch_us(moment) = epoch_us(TIMESTAMPTZ '280001-03-01 01:02:03.654321+05:30') FROM extended_zoned")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Bool(true)]]
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_microsecond_grid_types_refuse_submicro_edits() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE temporal_grid (id INTEGER PRIMARY KEY, clock TIME, event_at TIMESTAMP, \
             second_precision TIMESTAMP_S, milli_precision TIMESTAMP_MS)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO temporal_grid VALUES (1, TIME '12:34:56.123456', \
             TIMESTAMP '2026-09-29 12:34:56.123456', \
             TIMESTAMP_S '2026-09-29 12:34:56', TIMESTAMP_MS '2026-09-29 12:34:56.123')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "temporal_grid").await.unwrap();
    let clock_index = columns.iter().position(|column| column.name == "clock").unwrap();
    let stamp_index = columns.iter().position(|column| column.name == "event_at").unwrap();
    let seconds_index = columns
        .iter()
        .position(|column| column.name == "second_precision")
        .unwrap();
    let millis_index = columns
        .iter()
        .position(|column| column.name == "milli_precision")
        .unwrap();
    let rejected_clock = parse_input_for_driver("12:34:56.123456789", Some(&columns[clock_index]), "duckdb");
    let rejected_stamp = parse_input_for_driver("2026-09-29 12:34:56.123456789", Some(&columns[stamp_index]), "duckdb");
    let rejected_seconds =
        parse_input_for_driver("2026-09-29 12:34:56.123456789", Some(&columns[seconds_index]), "duckdb");
    let rejected_millis =
        parse_input_for_driver("2026-09-29 12:34:56.123456789", Some(&columns[millis_index]), "duckdb");
    assert!(
        rejected_clock.is_err(),
        "TIME grid edits must not lose sub-microsecond digits"
    );
    assert!(
        rejected_stamp.is_err(),
        "TIMESTAMP grid edits must not lose sub-microsecond digits"
    );
    assert!(
        rejected_seconds.is_err(),
        "TIMESTAMP_S grid edits must not lose fractional seconds"
    );
    assert!(
        rejected_millis.is_err(),
        "TIMESTAMP_MS grid edits must not lose sub-millisecond digits"
    );
    assert_eq!(
        connection
            .query_params(
                "SELECT CAST(CAST(? AS TIME) AS VARCHAR), CAST(CAST(? AS TIMESTAMP) AS VARCHAR), \
                 CAST(CAST(? AS TIMESTAMP_S) AS VARCHAR), CAST(CAST(? AS TIMESTAMP_MS) AS VARCHAR)",
                &[
                    Value::Text("12:34:56.123456789".into()),
                    Value::Text("2026-09-29 12:34:56.123456789".into()),
                    Value::Text("2026-09-29 12:34:56.123456789".into()),
                    Value::Text("2026-09-29 12:34:56.123456789".into()),
                ],
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("12:34:56.123456".into()),
            Value::Text("2026-09-29 12:34:56.123456".into()),
            Value::Text("2026-09-29 12:34:56".into()),
            Value::Text("2026-09-29 12:34:56.123".into())
        ]],
        "DuckDB casts to microsecond TIME/TIMESTAMP truncate unsupported nanoseconds"
    );
    assert_eq!(
        connection
            .query(
                "SELECT CAST(clock AS VARCHAR), CAST(event_at AS VARCHAR), \
                 CAST(second_precision AS VARCHAR), CAST(milli_precision AS VARCHAR) \
                 FROM temporal_grid WHERE id = 1",
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("12:34:56.123456".into()),
            Value::Text("2026-09-29 12:34:56.123456".into()),
            Value::Text("2026-09-29 12:34:56".into()),
            Value::Text("2026-09-29 12:34:56.123".into())
        ]],
        "refused edits must leave both stored values unchanged"
    );
}

#[cfg(feature = "duckdb")]
#[tokio::test]
async fn value_contract_duckdb_nanosecond_grid_edits_preserve_native_values_and_sibling() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_duckdb::DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE nanosecond_grid (
                id INTEGER PRIMARY KEY,
                clock TIME_NS,
                moment TIMESTAMP_NS
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO nanosecond_grid VALUES
             (1, TIME_NS '12:34:56.111111111', TIMESTAMP_NS '1969-12-31 23:59:59.111111111'),
             (2, TIME_NS '08:00:00.222222222', TIMESTAMP_NS '2026-09-27 08:00:00.222222222')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "nanosecond_grid").await.unwrap();
    let clock_index = columns.iter().position(|column| column.name == "clock").unwrap();
    let moment_index = columns.iter().position(|column| column.name == "moment").unwrap();
    assert_eq!(columns[clock_index].data_type.to_ascii_uppercase(), "TIME_NS");
    assert_eq!(columns[moment_index].data_type.to_ascii_uppercase(), "TIMESTAMP_NS");
    let before = connection
        .query("SELECT id, clock::VARCHAR, moment::VARCHAR FROM nanosecond_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        before.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("12:34:56.111111111".into()),
                Value::Text("1969-12-31 23:59:59.111111111".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("08:00:00.222222222".into()),
                Value::Text("2026-09-27 08:00:00.222222222".into()),
            ],
        ]
    );

    let edits = [
        (
            clock_index,
            parse_input_for_driver("12:34:56.123456789", Some(&columns[clock_index]), "duckdb").unwrap(),
        ),
        (
            moment_index,
            parse_input_for_driver("1969-12-31 23:59:59.123456789", Some(&columns[moment_index]), "duckdb").unwrap(),
        ),
    ];
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "duckdb",
        None,
        "nanosecond_grid",
        &columns,
        &edits,
        &[before.rows[0][0].clone()],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let saved = connection
        .query(
            "SELECT id, typeof(clock), clock::VARCHAR,
                    clock = TIME_NS '12:34:56.123456789',
                    typeof(moment), moment::VARCHAR,
                    moment = TIMESTAMP_NS '1969-12-31 23:59:59.123456789'
             FROM nanosecond_grid ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        saved.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("TIME_NS".into()),
                Value::Text("12:34:56.123456789".into()),
                Value::Bool(true),
                Value::Text("TIMESTAMP_NS".into()),
                Value::Text("1969-12-31 23:59:59.123456789".into()),
                Value::Bool(true),
            ],
            vec![
                Value::Int(2),
                Value::Text("TIME_NS".into()),
                Value::Text("08:00:00.222222222".into()),
                Value::Bool(false),
                Value::Text("TIMESTAMP_NS".into()),
                Value::Text("2026-09-27 08:00:00.222222222".into()),
                Value::Bool(false),
            ],
        ]
    );
}

#[test]
fn value_contract_duckdb_time_and_timestamp_parsers_refuse_submicro_edits() {
    for (data_type, input) in [
        ("TIME", "12:34:56.123456789"),
        ("TIMESTAMP", "2026-09-29 12:34:56.123456789"),
    ] {
        assert!(
            parse_input_for_driver(input, Some(&col(data_type, false)), "duckdb").is_err(),
            "{data_type} must refuse a value DuckDB stores at microsecond precision"
        );
    }
    assert!(matches!(
        parse_input_for_driver("12:34:56.123456000", Some(&col("TIME", false)), "duckdb"),
        Ok(Value::Time(time)) if time.nanosecond() == 123_456_000
    ));
    assert_eq!(
        parse_input_for_driver("12:34:56.123456789", Some(&col("TIME_NS", false)), "duckdb").unwrap(),
        Value::Text("12:34:56.123456789".into()),
        "TIME_NS remains exact text instead of being parsed at lower precision"
    );
    let aligned_timestamp = parse_input_for_driver(
        "2026-09-29 12:34:56.123456000",
        Some(&col("TIMESTAMP", false)),
        "duckdb",
    );
    assert!(
        matches!(aligned_timestamp, Ok(Value::DateTime(timestamp)) if timestamp.nanosecond() == 123_456_000),
        "{aligned_timestamp:?}"
    );
    assert!(matches!(
        parse_input_for_driver(
            "2026-09-29 12:34:56.123456789",
            Some(&col("TIMESTAMP_NS", false)),
            "duckdb"
        ),
        Ok(Value::DateTime(timestamp)) if timestamp.nanosecond() == 123_456_789
    ));
    assert_eq!(
        parse_input_for_driver(
            "2026-09-29 12:34:56.123456789",
            Some(&col("TIMESTAMP_S", false)),
            "duckdb"
        )
        .unwrap_err(),
        "DuckDB TIMESTAMP_S precision cannot represent this value exactly"
    );
    assert_eq!(
        parse_input_for_driver(
            "2026-09-29 12:34:56.123456789",
            Some(&col("TIMESTAMP_MS", false)),
            "duckdb"
        )
        .unwrap_err(),
        "DuckDB TIMESTAMP_MS precision cannot represent this value exactly"
    );
    assert!(matches!(
        parse_input_for_driver(
            "2026-09-29 12:34:56.123000000",
            Some(&col("TIMESTAMP_MS", false)),
            "duckdb"
        ),
        Ok(Value::DateTime(timestamp)) if timestamp.nanosecond() == 123_000_000
    ));
}

#[test]
fn value_contract_duckdb_timestamptz_parser_refuses_submicro_edits() {
    let column = col("TIMESTAMP WITH TIME ZONE", false);
    let submicro = "2026-09-29T12:34:56.123456789+00:00";
    assert_eq!(
        parse_input_for_driver("2026-09-29T12:34:56.123456+00:00", Some(&column), "duckdb").unwrap(),
        Value::TimestampTz(
            chrono::DateTime::parse_from_rfc3339("2026-09-29T12:34:56.123456Z")
                .unwrap()
                .to_utc()
        )
    );
    assert_eq!(
        parse_input_for_driver("2026-09-29T12:34:56.123456000+00:00", Some(&column), "duckdb").unwrap(),
        Value::TimestampTz(
            chrono::DateTime::parse_from_rfc3339("2026-09-29T12:34:56.123456Z")
                .unwrap()
                .to_utc()
        ),
        "extra trailing zero digits are still exactly microsecond-aligned"
    );
    assert_eq!(
        parse_input_for_driver(submicro, Some(&column), "duckdb").unwrap_err(),
        "DuckDB TIMESTAMPTZ supports microsecond precision only"
    );
    assert_eq!(
        parse_input_for_driver("280000-02-29T12:34:56.123456+05:30", Some(&column), "duckdb").unwrap(),
        Value::Text("280000-02-29T12:34:56.123456+05:30".into())
    );
    assert_eq!(
        parse_input_for_driver("0001-01-01 (BC) 12:34:56.123456+00:00", Some(&column), "duckdb").unwrap(),
        Value::Text("0001-01-01 (BC) 12:34:56.123456+00:00".into())
    );
    assert_eq!(
        parse_input_for_driver("280000-02-29T12:34:56.123456789+00:00", Some(&column), "duckdb").unwrap_err(),
        "DuckDB TIMESTAMPTZ supports microsecond precision only"
    );
    assert!(parse_input_for_driver("280001-02-29T12:34:56+00:00", Some(&column), "duckdb").is_err());
    assert!(parse_input_for_driver("280000-02-29T12:34:56+24:00", Some(&column), "duckdb").is_err());
    assert_eq!(
        parse_input_for_driver(submicro, Some(&col("TEXT", false)), "duckdb").unwrap(),
        Value::Text(submicro.into()),
        "ordinary text is not subject to TIMESTAMPTZ precision limits"
    );
    assert!(matches!(
        parse_input_for_driver(submicro, Some(&column), "sqlite").unwrap(),
        Value::TimestampTz(timestamp) if timestamp.timestamp_subsec_nanos() == 123_456_789
    ));
    assert_eq!(
        parse_input_for_driver(submicro, None, "duckdb").unwrap(),
        Value::Text(submicro.into())
    );
}
