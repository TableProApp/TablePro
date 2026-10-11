#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[path = "../../shared/server_restart.rs"]
mod server_restart;

#[path = "../../shared/connect_refusal.rs"]
mod connect_refusal;

#[path = "support/clickhouse.rs"]
mod clickhouse;

#[path = "support/database_listing.rs"]
mod database_listing;
#[path = "support/disconnection.rs"]
mod disconnection;
#[path = "support/enum_values.rs"]
mod enum_values;
#[path = "support/nested_values.rs"]
mod nested_values;
#[path = "support/temporal.rs"]
mod temporal;

use clickhouse::{connect, start_clickhouse};
use drivers_clickhouse::ClickhouseDriver;
use tablepro_core::sql_dialect::{build_full_row_update, build_single_cell_update};
use tablepro_core::{ColumnInfo, ConnectOptions, DatabaseDriver, DriverError, OperationControl, Value};
use testcontainers::{ContainerAsync, GenericImage};

#[tokio::test]
async fn an_unavailable_clickhouse_server_is_classified_as_connection_refused() {
    connect_refusal::assert_connection_refused(&ClickhouseDriver)
        .await
        .expect("ClickHouse setup refusal remains distinct from established disconnect");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_lost_clickhouse_server_is_reported_as_disconnected() {
    let (container, opts) = start_clickhouse().await;
    let connection = connect(opts.clone()).await;
    let initial = connection
        .query("SELECT 1")
        .await
        .expect("initial query reaches server");
    assert_eq!(initial.rows, vec![vec![Value::Int(1)]]);

    container.stop().await.expect("stop ClickHouse server");
    let error = connection
        .query("SELECT 1")
        .await
        .expect_err("query after server loss must fail");
    assert!(
        matches!(error, DriverError::Disconnected),
        "loss of an established ClickHouse server must be reported as disconnected, got {error:?}"
    );

    container.start().await.expect("restart ClickHouse server");
    let mut replacement_options = opts;
    replacement_options.host = container.get_host().await.expect("restarted host").to_string();
    replacement_options.port = container
        .get_host_port_ipv4(8123)
        .await
        .expect("restarted ClickHouse port");
    let recovered = server_restart::retry_operation("ClickHouse", || {
        let options = replacement_options.clone();
        async move {
            let replacement = ClickhouseDriver.connect(options).await?;
            replacement.query("SELECT 1").await
        }
    })
    .await
    .expect("ClickHouse restarts and accepts SELECT 1");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn wide_integer_binding_and_sql_export_preserve_exact_server_values() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE wide_integers (
            signed_min Int128,
            signed_max Int128,
            unsigned_max UInt128
        ) ENGINE = MergeTree ORDER BY tuple()",
    )
    .await
    .unwrap();
    let values = [
        Value::Text("-170141183460469231731687303715884105728".into()),
        Value::Text("170141183460469231731687303715884105727".into()),
        Value::Text("340282366920938463463374607431768211455".into()),
    ];
    conn.execute_params("INSERT INTO wide_integers VALUES (?, ?, ?)", &values)
        .await
        .unwrap();

    let result = conn
        .query("SELECT signed_min, signed_max, unsigned_max FROM wide_integers")
        .await
        .unwrap();
    assert_eq!(result.rows, vec![values.to_vec()]);

    let csv_options = tablepro_core::export::CsvOptions {
        sanitize_formulas: false,
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&result.columns, &result.rows, &csv_options);
    assert_eq!(
        csv,
        "signed_min,signed_max,unsigned_max\n-170141183460469231731687303715884105728,170141183460469231731687303715884105727,340282366920938463463374607431768211455\n"
    );
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let imported = tablepro_core::import::row_to_values(
        &sheet.rows[0],
        &[Some(0), Some(1), Some(2)],
        &result.columns,
        &import_options,
        2,
    )
    .unwrap();
    assert_eq!(imported, values);

    let safe_csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    assert_eq!(
        safe_csv,
        "signed_min,signed_max,unsigned_max\n\"'-170141183460469231731687303715884105728\",170141183460469231731687303715884105727,340282366920938463463374607431768211455\n"
    );
    let safe_sheet = tablepro_core::import::read_csv(safe_csv.as_bytes(), &import_options, None).unwrap();
    let safe_imported = tablepro_core::import::row_to_values(
        &safe_sheet.rows[0],
        &[Some(0), Some(1), Some(2)],
        &result.columns,
        &import_options,
        2,
    )
    .unwrap();
    assert_eq!(safe_imported, values);

    conn.execute(
        "CREATE TABLE wide_integer_copy (
            signed_min Int128,
            signed_max Int128,
            unsigned_max UInt128
        ) ENGINE = MergeTree ORDER BY tuple()",
    )
    .await
    .unwrap();
    let export = tablepro_core::sql_literal::build_insert_literal(
        "clickhouse",
        None,
        "wide_integer_copy",
        &result.columns,
        &result.rows[0],
    )
    .unwrap();
    conn.execute(&export).await.unwrap();

    let reimported = conn
        .query("SELECT signed_min, signed_max, unsigned_max FROM wide_integer_copy")
        .await
        .unwrap();
    assert_eq!(reimported.rows, vec![values.to_vec()]);

    conn.execute(
        "CREATE TABLE wide_integer_csv_copy (
            signed_min Int128,
            signed_max Int128,
            unsigned_max UInt128
        ) ENGINE = MergeTree ORDER BY tuple()",
    )
    .await
    .unwrap();
    conn.execute_params("INSERT INTO wide_integer_csv_copy VALUES (?, ?, ?)", &safe_imported)
        .await
        .unwrap();
    let csv_roundtrip = conn
        .query("SELECT signed_min, signed_max, unsigned_max FROM wide_integer_csv_copy")
        .await
        .unwrap();
    assert_eq!(csv_roundtrip.rows, vec![values.to_vec()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn wide_integer_grid_edits_preserve_exact_values_and_row_identity() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE wide_grid_edits (
            id UInt64,
            signed_amount Int128,
            unsigned_amount UInt128
        ) ENGINE = MergeTree ORDER BY id",
    )
    .await
    .unwrap();
    conn.execute_params(
        "INSERT INTO wide_grid_edits VALUES (?, ?, ?), (?, ?, ?)",
        &[
            Value::Int(1),
            Value::Text("-170141183460469231731687303715884105728".into()),
            Value::Text("340282366920938463463374607431768211455".into()),
            Value::Int(2),
            Value::Text("170141183460469231731687303715884105727".into()),
            Value::Text("0".into()),
        ],
    )
    .await
    .unwrap();

    let columns = conn.fetch_columns(None, "wide_grid_edits").await.unwrap();
    let result = conn
        .query("SELECT id, signed_amount, unsigned_amount FROM wide_grid_edits ORDER BY id")
        .await
        .unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let signed_index = columns
        .iter()
        .position(|column| column.name == "signed_amount")
        .unwrap();
    let unsigned_index = columns
        .iter()
        .position(|column| column.name == "unsigned_amount")
        .unwrap();
    assert!(columns[id_index].primary_key);
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "wide_grid_edits",
        &columns,
        &[
            (
                signed_index,
                Value::Text("-170141183460469231731687303715884105727".into()),
            ),
            (
                unsigned_index,
                Value::Text("340282366920938463463374607431768211454".into()),
            ),
        ],
        &[result.rows[0][id_index].clone()],
    )
    .unwrap();
    conn.execute_in_transaction(&[update]).await.unwrap();

    let after = conn
        .query("SELECT id, signed_amount, unsigned_amount FROM wide_grid_edits ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        after.rows[1],
        vec![
            Value::Int(2),
            Value::Text("170141183460469231731687303715884105727".into()),
            Value::Text("0".into()),
        ]
    );
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "wide_grid_edits",
        &columns,
        &[
            (
                signed_index,
                Value::Text("170141183460469231731687303715884105726".into()),
            ),
            (unsigned_index, Value::Text("1".into())),
        ],
        &[after.rows[1][id_index].clone()],
    )
    .unwrap();
    conn.execute_in_transaction(&[update]).await.unwrap();

    let final_rows = conn
        .query("SELECT id, signed_amount, unsigned_amount FROM wide_grid_edits ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        final_rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("-170141183460469231731687303715884105727".into()),
                Value::Text("340282366920938463463374607431768211454".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("170141183460469231731687303715884105726".into()),
                Value::Text("1".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn copied_in_clause_keeps_backslash_payload_as_data() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    let payload = Value::Text("x\\' OR 1=1 -- ".into());
    let clause = tablepro_core::export::render_in_clause("clickhouse", &[vec![payload.clone()]], 0);
    let literal = tablepro_core::sql_literal::render_sql_literal("clickhouse", &payload).unwrap();
    let result = conn
        .query(&format!("SELECT {literal} WHERE {literal} IN {}", clause.sql))
        .await
        .unwrap();
    assert_eq!(result.rows, vec![vec![payload]]);
    let unmatched = conn
        .query(&format!("SELECT 'unrelated' WHERE 'unrelated' IN {}", clause.sql))
        .await
        .unwrap();
    assert!(unmatched.rows.is_empty());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_and_pk_detection() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE pk_demo (
            id UInt64,
            name String,
            note Nullable(String)
        ) ENGINE = MergeTree
        ORDER BY id",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO pk_demo (id, name, note) VALUES (1, 'a', NULL), (2, 'b', 'second')")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "pk_demo"));

    let cols = conn.fetch_columns(None, "pk_demo").await.unwrap();
    assert_eq!(cols.len(), 3);
    let id_col = cols.iter().find(|c| c.name == "id").unwrap();
    assert!(id_col.primary_key, "ORDER BY key must be detected as primary_key");
    assert!(!id_col.nullable);
    let note_col = cols.iter().find(|c| c.name == "note").unwrap();
    assert!(!note_col.primary_key);
    assert!(note_col.nullable);

    // A MergeTree sorting key allows duplicates, so the index must not
    // claim uniqueness the engine does not enforce.
    let indexes = conn.fetch_indexes(None, "pk_demo").await.unwrap();
    assert_eq!(indexes.len(), 1);
    assert_eq!(indexes[0].columns, vec!["id".to_string()]);
    assert!(indexes[0].primary);
    assert!(!indexes[0].unique);

    let result = conn.fetch_rows(None, "pk_demo", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn views_appear_in_the_table_list() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE base (id UInt64) ENGINE = MergeTree ORDER BY id")
        .await
        .unwrap();
    conn.execute("CREATE VIEW base_view AS SELECT id FROM base")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "base"));
    assert!(
        tables.iter().any(|t| t.name == "base_view"),
        "views must be listed alongside tables"
    );
}

/// The inline-edit Save path renders its UPDATE through
/// `sql_dialect`, which has to emit `ALTER TABLE … UPDATE` for
/// ClickHouse. A plain `UPDATE` is a syntax error before 25.7, so this
/// covers the dialect and the driver's bind path together.
#[tokio::test]
#[ignore = "requires docker"]
async fn inline_edit_update_applies() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE edits (id UInt64, name String) ENGINE = MergeTree ORDER BY id")
        .await
        .unwrap();
    conn.execute("INSERT INTO edits VALUES (1, 'before'), (2, 'other')")
        .await
        .unwrap();

    let columns = conn.fetch_columns(None, "edits").await.unwrap();
    let original = vec![Value::Int(1), Value::Text("before".into())];
    let (sql, params) = build_single_cell_update(
        "clickhouse",
        "edits",
        &columns,
        &original,
        1,
        Value::Text("after".into()),
    )
    .unwrap();
    assert!(sql.starts_with("ALTER TABLE"), "unexpected dialect: {sql}");
    conn.execute_in_transaction(&[(sql, params)]).await.unwrap();

    let result = conn.query("SELECT name FROM edits ORDER BY id").await.unwrap();
    assert_eq!(result.rows[0][0], Value::Text("after".into()));
    assert_eq!(result.rows[1][0], Value::Text("other".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn full_row_update_applies() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE rows_edit (id UInt64, a String, b Int64) ENGINE = MergeTree ORDER BY id")
        .await
        .unwrap();
    conn.execute("INSERT INTO rows_edit VALUES (1, 'x', 10)").await.unwrap();

    let columns: Vec<ColumnInfo> = conn.fetch_columns(None, "rows_edit").await.unwrap();
    let original = vec![Value::Int(1), Value::Text("x".into()), Value::Int(10)];
    let new_values = vec![Value::Int(1), Value::Text("y".into()), Value::Int(20)];
    let (sql, params) = build_full_row_update("clickhouse", "rows_edit", &columns, &original, &new_values).unwrap();
    conn.execute_in_transaction(&[(sql, params)]).await.unwrap();

    let result = conn.query("SELECT a, b FROM rows_edit WHERE id = 1").await.unwrap();
    assert_eq!(result.rows[0][0], Value::Text("y".into()));
    assert_eq!(result.rows[0][1], Value::Int(20));
}

/// A row whose text contains an apostrophe and a `?` would corrupt the
/// bind pass if the scanner walked the SQL blind.
#[tokio::test]
#[ignore = "requires docker"]
async fn literals_with_quotes_and_placeholders_round_trip() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE quoting (id UInt64, note String) ENGINE = MergeTree ORDER BY id")
        .await
        .unwrap();
    let tricky = "it's a ? and a $1 \\ backslash";
    conn.execute_params(
        "INSERT INTO quoting (id, note) VALUES (?, ?)",
        &[Value::Int(1), Value::Text(tricky.into())],
    )
    .await
    .unwrap();

    let result = conn
        .query_params("SELECT note FROM quoting WHERE id = ?", &[Value::Int(1)])
        .await
        .unwrap();
    assert_eq!(result.rows[0][0], Value::Text(tricky.into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn parameterised_types_decode_to_typed_values() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE typed (
            id UInt64,
            price Decimal(9, 2),
            stamp DateTime64(3),
            label LowCardinality(Nullable(String))
        ) ENGINE = MergeTree
        ORDER BY id",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO typed VALUES (1, 12.34, '2024-06-15 08:30:00.123', 'tag')")
        .await
        .unwrap();

    let cols = conn.fetch_columns(None, "typed").await.unwrap();
    let label = cols.iter().find(|c| c.name == "label").unwrap();
    assert!(label.nullable, "LowCardinality(Nullable(T)) must read as nullable");

    let result = conn.query("SELECT price, stamp, label FROM typed").await.unwrap();
    assert_eq!(result.rows[0][0], Value::Decimal("12.34".parse().unwrap()));
    assert!(
        matches!(result.rows[0][1], Value::DateTime(_)),
        "DateTime64(3) decoded as {:?}",
        result.rows[0][1]
    );
    assert_eq!(result.rows[0][2], Value::Text("tag".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_datetime64_precision_0_through_9_is_exact() {
    use chrono::Timelike;

    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    let scale_columns = (0..=9)
        .map(|scale| format!("p{scale} DateTime64({scale})"))
        .collect::<Vec<_>>()
        .join(", ");
    conn.execute(&format!(
        "CREATE TABLE temporal_precision (id UInt8, {scale_columns}) ENGINE = MergeTree ORDER BY id"
    ))
    .await
    .unwrap();

    let stamp = chrono::NaiveDate::from_ymd_opt(2026, 9, 27)
        .unwrap()
        .and_hms_nano_opt(12, 34, 56, 123_456_789)
        .unwrap();
    let values = vec![Value::DateTime(stamp); 10];
    let placeholders = vec!["?"; values.len()].join(", ");
    conn.execute_params(
        &format!("INSERT INTO temporal_precision VALUES (1, {placeholders})"),
        &values,
    )
    .await
    .unwrap();

    let columns = (0..=9).map(|scale| format!("p{scale}")).collect::<Vec<_>>();
    let epochs = columns
        .iter()
        .map(|column| format!("toUnixTimestamp64Nano({column})"))
        .collect::<Vec<_>>();
    let result = conn
        .query(&format!(
            "SELECT {}, {} FROM temporal_precision WHERE id = 1",
            columns.join(", "),
            epochs.join(", ")
        ))
        .await
        .unwrap();

    // ClickHouse truncates fractional digits beyond a column's declared scale.
    // Keep this expectation independent of the adapter's scale conversion.
    let expected_nanos = [
        0,
        100_000_000,
        120_000_000,
        123_000_000,
        123_400_000,
        123_450_000,
        123_456_000,
        123_456_700,
        123_456_780,
        123_456_789,
    ];
    let mut expected_row: Vec<Value> = expected_nanos
        .iter()
        .map(|nanos| Value::DateTime(stamp.with_nanosecond(*nanos).unwrap()))
        .collect();
    expected_row.extend(expected_nanos.iter().map(|nanos| {
        Value::Int(
            stamp
                .with_nanosecond(*nanos)
                .unwrap()
                .and_utc()
                .timestamp_nanos_opt()
                .unwrap(),
        )
    }));
    assert_eq!(
        result.rows,
        vec![expected_row],
        "all DateTime64 scales 0 through 9 must retain exactly their declared precision"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_datetime64_named_timezone_preserves_the_instant() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    for (local, scale, timezone, utc) in [
        (
            "2026-09-27 12:34:56.123456",
            6,
            "Asia/Tokyo",
            "2026-09-27T03:34:56.123456Z",
        ),
        (
            "2026-09-27 00:15:00.123456789",
            9,
            "Asia/Kathmandu",
            "2026-09-26T18:30:00.123456789Z",
        ),
    ] {
        let result = conn
            .query(&format!(
                "SELECT toDateTime64('{local}', {scale}, '{timezone}') AS stamp"
            ))
            .await
            .unwrap();
        let instant = chrono::DateTime::parse_from_rfc3339(utc).unwrap().to_utc();
        assert_eq!(
            result.rows,
            vec![vec![Value::TimestampTz(instant)]],
            "DateTime64 {timezone} metadata must be applied to the displayed local clock"
        );

        let expected = Value::TimestampTz(instant);
        let bound = conn
            .query_params(
                &format!("SELECT CAST(? AS DateTime64({scale}, '{timezone}'))"),
                std::slice::from_ref(&expected),
            )
            .await
            .unwrap();
        assert_eq!(
            bound.rows,
            vec![vec![expected.clone()]],
            "bound timestamp timezone round trip for {timezone}"
        );

        let literal = tablepro_core::sql_literal::render_sql_literal("clickhouse", &expected).unwrap();
        let exported = conn
            .query(&format!("SELECT CAST({literal} AS DateTime64({scale}, '{timezone}'))"))
            .await
            .unwrap();
        assert_eq!(
            exported.rows,
            vec![vec![expected]],
            "SQL literal timezone round trip for {timezone}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_ambiguous_datetime64_local_time_is_refused() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    let result = conn
        .query(
            "SELECT stamp, toString(stamp) AS local_text, toUnixTimestamp64Milli(stamp) AS epoch_ms \
             FROM (SELECT toDateTime64('2024-11-03 01:30:00', 3, 'America/New_York') AS stamp)",
        )
        .await
        .unwrap();

    let value = &result.rows[0][0];
    assert!(
        matches!(value, Value::Undecodable(reason) if reason.contains("ambiguous or nonexistent local time")),
        "{value:?}"
    );
    assert_eq!(result.rows[0][1], Value::Text("2024-11-03 01:30:00.000".into()));
    assert!(matches!(
        result.rows[0][2],
        Value::Int(1_730_611_800_000 | 1_730_615_400_000)
    ));
    assert!(tablepro_core::sql_literal::render_sql_literal("clickhouse", value).is_err());
    assert!(
        conn.query_params("SELECT ?", std::slice::from_ref(value))
            .await
            .is_err()
    );

    let lord_howe = conn
        .query(
            "SELECT stamp, toString(stamp) AS local_text, toUnixTimestamp64Milli(stamp) AS epoch_ms \
             FROM (SELECT toDateTime64('2024-04-07 01:45:00', 3, 'Australia/Lord_Howe') AS stamp)",
        )
        .await
        .unwrap();
    let value = &lord_howe.rows[0][0];
    assert!(
        matches!(value, Value::Undecodable(reason) if reason.contains("ambiguous or nonexistent local time")),
        "{value:?}"
    );
    assert_eq!(lord_howe.rows[0][1], Value::Text("2024-04-07 01:45:00.000".into()));
    assert!(matches!(
        lord_howe.rows[0][2],
        Value::Int(1_712_414_700_000 | 1_712_416_500_000)
    ));
    assert!(tablepro_core::sql_literal::render_sql_literal("clickhouse", value).is_err());
    assert!(
        conn.query_params("SELECT ?", std::slice::from_ref(value))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_nonexistent_datetime64_input_matches_server_normalization() {
    let (_container, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    let result = conn
        .query(
            "SELECT stamp, toString(stamp) AS local_text, toUnixTimestamp64Milli(stamp) AS epoch_ms \
             FROM (SELECT toDateTime64('2024-03-10 02:30:00', 3, 'America/New_York') AS stamp)",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::TimestampTz("2024-03-10T06:30:00Z".parse().unwrap()),
            Value::Text("2024-03-10 01:30:00.000".into()),
            Value::Int(1_710_052_200_000),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_roundtrip_common_types() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE roundtrip (
            id UInt64,
            b Bool,
            i64 Int64,
            f64 Float64,
            t String,
            d Date,
            nullable_text Nullable(String)
        ) ENGINE = MergeTree
        ORDER BY id",
    )
    .await
    .unwrap();

    conn.execute_params(
        "INSERT INTO roundtrip (id, b, i64, f64, t, d, nullable_text) VALUES (?, ?, ?, ?, ?, ?, ?)",
        &[
            Value::Int(1),
            Value::Bool(true),
            Value::Int(42),
            Value::Float(1.5),
            Value::Text("hello".into()),
            Value::Date(chrono::NaiveDate::from_ymd_opt(2024, 6, 15).unwrap()),
            Value::Null,
        ],
    )
    .await
    .unwrap();

    let result = conn
        .query("SELECT id, b, i64, f64, t, d, nullable_text FROM roundtrip WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(result.rows.len(), 1);
    let row = &result.rows[0];
    assert_eq!(row[0], Value::Int(1));
    assert_eq!(row[1], Value::Bool(true));
    assert_eq!(row[2], Value::Int(42));
    assert!(matches!(row[3], Value::Float(f) if (f - 1.5).abs() < 1e-9));
    assert_eq!(row[4], Value::Text("hello".into()));
    assert_eq!(
        row[5],
        Value::Date(chrono::NaiveDate::from_ymd_opt(2024, 6, 15).unwrap())
    );
    assert_eq!(row[6], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pagination_and_truncated_flag() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE n (i UInt64) ENGINE = MergeTree ORDER BY i")
        .await
        .unwrap();
    conn.execute("INSERT INTO n SELECT number + 1 FROM numbers(10)")
        .await
        .unwrap();

    // ClickHouse applies OFFSET after the sort key, so rows 6..8 are
    // the deterministic third page of three.
    let page = conn.fetch_rows(None, "n", 5, 3).await.unwrap();
    assert_eq!(page.rows.len(), 3);
    assert_eq!(page.rows[0][0], Value::Int(6));
    assert_eq!(page.rows[2][0], Value::Int(8));
    // A page carries its own LIMIT, so the server never sends a row past
    // it and the cap has nothing to cut. Same as the sqlx drivers:
    // `truncated` describes the row cap, not the page window.
    assert!(!page.truncated);

    let last = conn.fetch_rows(None, "n", 8, 3).await.unwrap();
    assert_eq!(last.rows.len(), 2);
    assert!(!last.truncated);
}

/// The decoded-result budget truncates arbitrary queries and reports it.
#[tokio::test]
#[ignore = "requires docker"]
async fn query_truncates_when_result_memory_budget_is_exceeded() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    let cap = tablepro_core::MAX_QUERY_ROWS;
    let over = conn
        .query(&format!("SELECT number FROM numbers({})", cap + 1))
        .await
        .unwrap();
    assert!(!over.rows.is_empty());
    assert!(over.rows.len() < cap, "decoded memory budget binds before row cap");
    assert_eq!(over.rows.first(), Some(&vec![Value::Int(0)]));
    assert_eq!(over.rows.last(), Some(&vec![Value::Int((over.rows.len() - 1) as i64)]));
    assert!(over.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    let err = conn
        .query("SELECT * FROM definitely_missing_table_xyz")
        .await
        .unwrap_err();
    assert!(matches!(err, tablepro_core::DriverError::Query { .. }));
}

async fn running_query_count(connection: &dyn tablepro_core::Connection, query_id: &str) -> i64 {
    let sql = format!("SELECT count() FROM system.processes WHERE query_id = '{query_id}'");
    let result = connection.query(&sql).await.expect("inspect system.processes");
    match result.rows.first().and_then(|row| row.first()) {
        Some(Value::Int(count)) => *count,
        other => panic!("unexpected count row: {other:?}"),
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_driver_declares_server_side_cancellation() {
    let (_container, opts) = start_clickhouse().await;
    let connection = connect(opts).await;
    assert!(connection.supports_server_cancellation());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancelled_query_is_killed_on_the_server_and_the_client_stays_usable() {
    let (_container, opts) = start_clickhouse().await;
    let connection: std::sync::Arc<dyn tablepro_core::Connection> =
        ClickhouseDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;

    let token = tokio_util::sync::CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move {
        operation_connection
            .query_controlled("SELECT count() FROM numbers(200000000000)", &control)
            .await
    });

    let mut running = String::new();
    for _ in 0..200 {
        let result = observer
            .query("SELECT query_id FROM system.processes WHERE query LIKE '%numbers(200000000000)%'")
            .await
            .expect("inspect system.processes");
        if let Some(Value::Text(query_id)) = result.rows.first().and_then(|row| row.first()) {
            running = query_id.clone();
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(!running.is_empty(), "the probe query never reached system.processes");

    token.cancel();
    let error = task
        .await
        .expect("query task")
        .expect_err("the query must be cancelled");
    assert!(matches!(error, DriverError::Cancelled), "unexpected error: {error:?}");

    for _ in 0..200 {
        if running_query_count(observer.as_ref(), &running).await == 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(
        running_query_count(observer.as_ref(), &running).await,
        0,
        "the killed query must leave system.processes"
    );

    let result = connection.query("SELECT 1").await.expect("the client remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_comment_round_trips_and_an_uncommented_column_reads_as_none() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE comment_demo (
            id UInt64,
            label String COMMENT 'what the row is called'
        ) ENGINE = MergeTree
        ORDER BY id",
    )
    .await
    .unwrap();

    let cols = conn.fetch_columns(None, "comment_demo").await.unwrap();
    let id = cols.iter().find(|c| c.name == "id").unwrap();
    let label = cols.iter().find(|c| c.name == "label").unwrap();
    assert_eq!(label.comment.as_deref(), Some("what the row is called"));
    assert_eq!(
        id.comment, None,
        "an uncommented column reports the engine's empty string as no comment"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
    let (_container, options) = start_clickhouse().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE binary_exports (id INTEGER, payload Nullable(String)) ENGINE = Memory")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
    let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
    for (id, value) in values.iter().enumerate() {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "clickhouse",
            None,
            "binary_exports",
            &columns,
            &[Value::Int(id as i64), value.clone()],
        )
        .unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let result = conn
        .query("SELECT lower(hex(payload)) FROM binary_exports ORDER BY id")
        .await
        .unwrap();
    let hex: String = (0u8..=255).map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Null],
            vec![Value::Text(String::new())],
            vec![Value::Text(hex)]
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn decimal_and_nonfinite_results_are_not_rounded_or_changed_to_null() {
    let (_container, options) = start_clickhouse().await;
    let conn = connect(options).await;
    let result = conn.query("SELECT toDecimal256('12345678901234567890.123456789012345678901234567890', 30) AS exact, toString(exact), toFloat64('nan'), toFloat64('inf'), toFloat64('-inf'), CAST(NULL AS Nullable(Float64))").await.unwrap();
    let row = &result.rows[0];
    let actual = match &row[0] {
        Value::Text(text) => text.clone(),
        Value::Decimal(decimal) => decimal.to_string(),
        other => panic!("unexpected decimal: {other:?}"),
    };
    assert_eq!(actual, "12345678901234567890.123456789012345678901234567890");
    assert!(matches!(row[2], Value::Float(number) if number.is_nan()));
    assert!(matches!(row[3], Value::Float(number) if number == f64::INFINITY));
    assert!(matches!(row[4], Value::Float(number) if number == f64::NEG_INFINITY));
    assert_eq!(row[5], Value::Null);
}

#[path = "../../../core/tests/support/value_contract.rs"]
mod value_contract;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_scalar_boundaries_through_parameters_and_exports() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    value_contract::assert_scalar_contract(connection.as_ref(), "clickhouse").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn decimal_results_keep_the_declared_scale_including_trailing_zeroes() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE scaled (id UInt8, price Decimal(10, 2), wide Decimal(38, 10)) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO scaled VALUES (1, 2.50, 1.5), (2, 0, 0), (3, -1.10, -0.0000000010)")
        .await
        .unwrap();
    let result = connection
        .query("SELECT price, wide, toDecimal64('3.10', 3) FROM scaled ORDER BY id")
        .await
        .unwrap();
    let rendered: Vec<Vec<String>> = result
        .rows
        .iter()
        .map(|row| {
            row.iter()
                .map(|value| match value {
                    Value::Decimal(decimal) => decimal.to_string(),
                    other => panic!("unexpected decimal: {other:?}"),
                })
                .collect()
        })
        .collect();
    assert_eq!(
        rendered,
        [
            ["2.50", "1.5000000000", "3.100"],
            ["0.00", "0.0000000000", "3.100"],
            ["-1.10", "-0.0000000010", "3.100"],
        ]
    );
}

fn fractional_stamps() -> (chrono::NaiveDateTime, chrono::NaiveDateTime) {
    let local = chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
        .unwrap()
        .and_hms_nano_opt(8, 30, 0, 123_456_789)
        .unwrap();
    let instant = chrono::NaiveDate::from_ymd_opt(1969, 12, 31)
        .unwrap()
        .and_hms_micro_opt(23, 59, 59, 654_321)
        .unwrap();
    (local, instant)
}

async fn create_stamp_table(connection: &dyn tablepro_core::Connection) {
    connection
        .execute("CREATE TABLE stamps (nanos DateTime64(9), micros DateTime64(6)) ENGINE = MergeTree ORDER BY nanos")
        .await
        .unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn temporal_parameters_keep_fractional_seconds() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    create_stamp_table(connection.as_ref()).await;
    let (local, instant) = fractional_stamps();
    let values = [Value::DateTime(local), Value::TimestampTz(instant.and_utc())];
    let expected = vec![vec![Value::DateTime(local), Value::DateTime(instant)]];
    connection
        .execute_params("INSERT INTO stamps VALUES (?, ?)", &values)
        .await
        .unwrap();
    let stored = connection.query("SELECT nanos, micros FROM stamps").await.unwrap();
    assert_eq!(stored.rows, expected);
    let bound = connection
        .query_params("SELECT CAST(? AS DateTime64(9)), CAST(? AS DateTime64(6))", &values)
        .await
        .unwrap();
    assert_eq!(bound.rows, expected);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn temporal_sql_exports_keep_fractional_seconds() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    create_stamp_table(connection.as_ref()).await;
    let (local, instant) = fractional_stamps();
    let literals: Vec<String> = [Value::DateTime(local), Value::TimestampTz(instant.and_utc())]
        .iter()
        .map(|value| tablepro_core::sql_literal::render_sql_literal("clickhouse", value).unwrap())
        .collect();
    connection
        .execute(&format!("INSERT INTO stamps VALUES ({}, {})", literals[0], literals[1]))
        .await
        .unwrap();
    let stored = connection.query("SELECT nanos, micros FROM stamps").await.unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![Value::DateTime(local), Value::DateTime(instant)]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn datetime64_nanosecond_boundaries_pin_server_clamp_and_local_refusal() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    let endpoints = connection
        .query(
            "WITH toDateTime64('1900-01-01 00:00:00.000000000', 9) AS lower_bound, \
                  toDateTime64('2262-04-11 23:47:16.854775807', 9) AS upper_bound \
             SELECT lower_bound, toUnixTimestamp64Nano(lower_bound), \
                    upper_bound, toUnixTimestamp64Nano(upper_bound)",
        )
        .await
        .expect("DateTime64(9) legal endpoints");
    assert_eq!(
        endpoints.rows,
        vec![vec![
            Value::DateTime(
                chrono::NaiveDate::from_ymd_opt(1900, 1, 1)
                    .unwrap()
                    .and_hms_opt(0, 0, 0)
                    .unwrap(),
            ),
            Value::Int(-2_208_988_800_000_000_000),
            Value::DateTime(
                chrono::NaiveDate::from_ymd_opt(2262, 4, 11)
                    .unwrap()
                    .and_hms_nano_opt(23, 47, 16, 854_775_807)
                    .unwrap(),
            ),
            Value::Int(i64::MAX),
        ]],
        "legal endpoints must retain the exact nanosecond server epoch"
    );

    let below = chrono::NaiveDate::from_ymd_opt(1899, 12, 31)
        .unwrap()
        .and_hms_nano_opt(23, 59, 59, 999_999_999)
        .unwrap();
    let requested = chrono::NaiveDate::from_ymd_opt(2262, 4, 12)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap();
    let clamped = connection
        .query(
            "SELECT toDateTime64('1899-12-31 23:59:59.999999999', 9), \
             toUnixTimestamp64Nano(toDateTime64('1899-12-31 23:59:59.999999999', 9))",
        )
        .await
        .expect("ClickHouse accepts and clamps a pre-1900 DateTime64(9) literal");
    assert_eq!(
        clamped.rows,
        vec![vec![
            Value::DateTime(
                chrono::NaiveDate::from_ymd_opt(1900, 1, 1)
                    .unwrap()
                    .and_hms_nano_opt(23, 59, 59, 999_999_999)
                    .unwrap(),
            ),
            Value::Int(-2_208_902_400_000_000_001),
        ]],
        "ClickHouse 24.8 clamps the year to 1900 while retaining the clock and fraction"
    );

    let above = connection
        .query("SELECT toDateTime64('2262-04-12 00:00:00.000000000', 9)")
        .await;
    assert!(
        matches!(above, Err(DriverError::Query { .. })),
        "ClickHouse 24.8 rejects the first nanosecond date beyond the upper bound"
    );

    let lower_parameter = connection
        .query_params("SELECT CAST(? AS DateTime64(9))", &[Value::DateTime(below)])
        .await;
    assert!(
        matches!(lower_parameter, Err(DriverError::Unsupported(_))),
        "values below the 1900 calendar boundary are refused before dispatch"
    );
    assert_eq!(
        tablepro_core::sql_literal::render_sql_literal("clickhouse", &Value::DateTime(below)),
        Err(tablepro_core::sql_literal::LiteralError::Unsupported)
    );

    let precision_nine_parameter = connection
        .query_params("SELECT CAST(? AS DateTime64(9))", &[Value::DateTime(requested)])
        .await;
    assert!(
        matches!(precision_nine_parameter, Err(DriverError::Query { .. })),
        "an explicit DateTime64(9) cast above its Int64 epoch bound must fail visibly"
    );
    let literal = tablepro_core::sql_literal::render_sql_literal("clickhouse", &Value::DateTime(requested))
        .expect("the same whole-second value has an exact lower-scale literal");
    assert_eq!(literal, "toDateTime64('2262-04-12 00:00:00', 0)");
}
