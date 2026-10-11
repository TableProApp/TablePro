#![allow(clippy::expect_used, clippy::unwrap_used)]

use super::parse_input_for_grid_cell;
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_clickhouse_enum8_and_enum16_grid_edits_preserve_labels_and_refuse_invalid_values() {
    use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig};
    use testcontainers::core::wait::HttpWaitStrategy;
    use testcontainers::core::{IntoContainerPort, WaitFor};
    use testcontainers::runners::AsyncRunner;
    use testcontainers::{GenericImage, ImageExt};

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
        .expect("start ClickHouse fixture");
    let connection = drivers_clickhouse::ClickhouseDriver
        .connect(ConnectOptions {
            host: container.get_host().await.expect("container host").to_string(),
            port: container.get_host_port_ipv4(8123).await.expect("HTTP port"),
            database: "default".into(),
            username: "default".into(),
            password: secrecy::SecretString::new("tablepro".to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .expect("connect to ClickHouse fixture");
    connection
        .execute(
            "CREATE TABLE enum16_grid (
                id UInt8,
                state Nullable(Enum16('low' = -32768, 'NULL' = 0, 'high' = 32767, '' = 1, 'O''Brien' = 2)),
                state8 Nullable(Enum8('low' = -128, 'NULL' = 0, 'high' = 127, '' = 1))
            ) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum16_grid VALUES (1, 'low', 'low'), (2, 'NULL', 'NULL'), (3, NULL, NULL), (4, 'high', 'high'), (5, 'low', 'low'), (6, 'low', 'low')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "enum16_grid").await.unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let state_index = columns.iter().position(|column| column.name == "state").unwrap();
    let state8_index = columns.iter().position(|column| column.name == "state8").unwrap();
    assert!(columns[id_index].primary_key, "id is the MergeTree ordering key");
    assert!(columns[state_index].nullable);
    assert!(columns[state_index].data_type.starts_with("Nullable(Enum16("));
    assert!(columns[state8_index].nullable);
    assert!(columns[state8_index].data_type.starts_with("Nullable(Enum8("));

    let high = parse_input_for_grid_cell("high", Some(&columns[state_index]), "clickhouse", None).unwrap();
    assert_eq!(high, Value::Text("high".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state_index, high)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let clear = parse_input_for_grid_cell("", Some(&columns[state_index]), "clickhouse", None).unwrap();
    assert_eq!(clear, Value::Null);
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state_index, clear)],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let empty_label = parse_input_for_grid_cell("''", Some(&columns[state_index]), "clickhouse", None).unwrap();
    assert_eq!(empty_label, Value::Text(String::new()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state_index, empty_label)],
        &[Value::Int(5)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let empty_enum8 = parse_input_for_grid_cell("''", Some(&columns[state8_index]), "clickhouse", None).unwrap();
    assert_eq!(empty_enum8, Value::Text(String::new()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state8_index, empty_enum8)],
        &[Value::Int(5)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let apostrophe_label =
        parse_input_for_grid_cell("'O''Brien'", Some(&columns[state_index]), "clickhouse", None).unwrap();
    assert_eq!(apostrophe_label, Value::Text("O'Brien".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state_index, apostrophe_label)],
        &[Value::Int(6)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let before_refusal = connection
        .query("SELECT id, state, CAST(assumeNotNull(state) AS Int16), isNull(state), state8, CAST(assumeNotNull(state8) AS Int8), isNull(state8) FROM enum16_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        before_refusal.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("high".into()),
                Value::Int(32767),
                Value::Int(0),
                Value::Text("low".into()),
                Value::Int(-128),
                Value::Int(0)
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Int(0),
                Value::Int(1),
                Value::Text("NULL".into()),
                Value::Int(0),
                Value::Int(0)
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Int(0),
                Value::Int(1),
                Value::Null,
                Value::Int(0),
                Value::Int(1)
            ],
            vec![
                Value::Int(4),
                Value::Text("high".into()),
                Value::Int(32767),
                Value::Int(0),
                Value::Text("high".into()),
                Value::Int(127),
                Value::Int(0)
            ],
            vec![
                Value::Int(5),
                Value::Text(String::new()),
                Value::Int(1),
                Value::Int(0),
                Value::Text(String::new()),
                Value::Int(1),
                Value::Int(0)
            ],
            vec![
                Value::Int(6),
                Value::Text("O'Brien".into()),
                Value::Int(2),
                Value::Int(0),
                Value::Text("low".into()),
                Value::Int(-128),
                Value::Int(0)
            ],
        ]
    );

    let invalid = parse_input_for_grid_cell("not-a-label", Some(&columns[state_index]), "clickhouse", None).unwrap();
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "clickhouse",
        None,
        "enum16_grid",
        &columns,
        &[(state_index, invalid)],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(connection.execute_in_transaction(&[update]).await.is_err());
    let after_refusal = connection
        .query("SELECT id, state, CAST(assumeNotNull(state) AS Int16), isNull(state), state8, CAST(assumeNotNull(state8) AS Int8), isNull(state8) FROM enum16_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(after_refusal.rows, before_refusal.rows);
}
