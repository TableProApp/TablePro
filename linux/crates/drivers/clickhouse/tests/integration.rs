use drivers_clickhouse::ClickhouseDriver;
use tablepro_core::sql_dialect::{build_full_row_update, build_single_cell_update};
use tablepro_core::{ColumnInfo, ConnectOptions, DatabaseDriver, Value};
use testcontainers::core::wait::HttpWaitStrategy;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

async fn start_clickhouse() -> (ContainerAsync<GenericImage>, ConnectOptions) {
    let container = GenericImage::new("clickhouse/clickhouse-server", "24.8")
        .with_exposed_port(8123.tcp())
        .with_wait_for(WaitFor::http(
            HttpWaitStrategy::new("/ping")
                .with_port(8123.tcp())
                .with_expected_status_code(200u16),
        ))
        .with_env_var("CLICKHOUSE_USER", "default")
        .with_env_var("CLICKHOUSE_PASSWORD", "tablepro")
        .with_env_var("CLICKHOUSE_DB", "default")
        .with_env_var("CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT", "1")
        .start()
        .await
        .expect("start clickhouse container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(8123).await.expect("port");
    let opts = ConnectOptions {
        host,
        port,
        database: "default".into(),
        username: "default".into(),
        password: secrecy::SecretString::new("tablepro".to_string().into()),
        use_tls: false,
    };
    (container, opts)
}

async fn connect(opts: ConnectOptions) -> Box<dyn tablepro_core::Connection> {
    ClickhouseDriver.connect(opts).await.expect("connect")
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

/// `MAX_QUERY_ROWS` bounds an arbitrary `query`; the flag has to fire
/// on the row past the cap, not on a result that merely fills it.
#[tokio::test]
#[ignore = "requires docker"]
async fn query_truncates_at_the_row_cap() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;

    let cap = tablepro_core::MAX_QUERY_ROWS;
    let exact = conn.query(&format!("SELECT number FROM numbers({cap})")).await.unwrap();
    assert_eq!(exact.rows.len(), cap);
    assert!(!exact.truncated, "a result of exactly the cap is complete");

    let over = conn
        .query(&format!("SELECT number FROM numbers({})", cap + 1))
        .await
        .unwrap();
    assert_eq!(over.rows.len(), cap);
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
