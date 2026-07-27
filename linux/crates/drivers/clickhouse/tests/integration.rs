use drivers_clickhouse::ClickhouseDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::core::wait::HttpWaitStrategy;
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

    let result = conn.fetch_rows(None, "pk_demo", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);
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
    for i in 1..=10 {
        conn.execute(&format!("INSERT INTO n VALUES ({i})")).await.unwrap();
    }

    let page = conn.fetch_rows(None, "n", 5, 3).await.unwrap();
    assert_eq!(page.rows.len(), 3);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    let err = conn.query("SELECT * FROM definitely_missing_table_xyz").await.unwrap_err();
    assert!(matches!(err, tablepro_core::DriverError::Query { .. }));
}
