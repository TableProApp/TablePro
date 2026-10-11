#[tokio::test]
async fn sqlite_length_any_csv_round_trip_preserves_integer_and_null_results() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE flexible (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO flexible VALUES \
             (1, 42), (2, 1.5), (3, 'aé🙂'), (4, ''), \
             (5, X'00FF'), (6, X'410042'), (7, CAST(X'410042' AS TEXT)), \
             (8, NULL), (9, '=1+1'), (10, 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, position INTEGER, result ANY, storage_class TEXT, bytes TEXT\
             ) STRICT",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id AS position, length(value) AS result, \
                    typeof(length(value)) AS storage_class, \
                    hex(length(value)) AS bytes \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, "NULL");
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(2), Value::Int(3), Value::Text("integer".into()), Value::Text("33".into())],
            vec![Value::Int(3), Value::Int(3), Value::Text("integer".into()), Value::Text("33".into())],
            vec![Value::Int(4), Value::Int(0), Value::Text("integer".into()), Value::Text("30".into())],
            vec![Value::Int(5), Value::Int(2), Value::Text("integer".into()), Value::Text("32".into())],
            vec![Value::Int(6), Value::Int(3), Value::Text("integer".into()), Value::Text("33".into())],
            vec![Value::Int(7), Value::Int(1), Value::Text("integer".into()), Value::Text("31".into())],
            vec![Value::Int(8), Value::Null, Value::Text("null".into()), Value::Text(String::new())],
            vec![Value::Int(9), Value::Int(4), Value::Text("integer".into()), Value::Text("34".into())],
            vec![Value::Int(10), Value::Int(4), Value::Text("integer".into()), Value::Text("34".into())],
        ]
    );

    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(result), result, hex(result) FROM restored ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        result
            .rows
            .iter()
            .map(|row| vec![row[2].clone(), row[1].clone(), row[3].clone()])
            .collect::<Vec<_>>()
    );
}
