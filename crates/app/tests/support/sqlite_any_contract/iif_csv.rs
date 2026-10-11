#[tokio::test]
async fn sqlite_iif_any_csv_round_trip_preserves_runtime_storage_classes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY) STRICT")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1), (2), (3), (4), (5)")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let expression = "iif(id = 1, 42, \
                         iif(id = 2, 1.5, \
                         iif(id = 3, '=1+1', \
                         iif(id = 4, X'00FF', NULL))))";
    let result = connection
        .query(&format!(
            "SELECT id AS position, {expression} AS result, \
                    typeof({expression}) AS storage_class \
             FROM flexible ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Int(42),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Int(2),
                Value::Float(1.5),
                Value::Text("real".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("=1+1".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(4),
                Value::Bytes(vec![0, 255]),
                Value::Text("blob".into()),
            ],
            vec![Value::Int(5), Value::Null, Value::Text("null".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("integer".into()), Value::Int(42)],
            vec![Value::Text("real".into()), Value::Float(1.5)],
            vec![Value::Text("text".into()), Value::Text("=1+1".into())],
            vec![Value::Text("blob".into()), Value::Bytes(vec![0, 255])],
            vec![Value::Text("null".into()), Value::Null],
        ]
    );
}
