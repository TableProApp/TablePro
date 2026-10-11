use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, Value};

#[tokio::test]
async fn stale_sqlite_grid_update_rolls_back_the_batch_and_preserves_the_original_value() {
    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE records (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO records VALUES (1, 'original')")
        .await
        .unwrap();
    connection
        .execute("UPDATE records SET payload = 'other writer' WHERE id = 1")
        .await
        .unwrap();
    let statements = vec![
        ("INSERT INTO records VALUES (2, 'batch')".into(), Vec::new()),
        (
            "UPDATE records SET payload = ?1 WHERE id = ?2 AND payload IS ?3".into(),
            vec![
                Value::Text("stale edit".into()),
                Value::Int(1),
                Value::Text("original".into()),
            ],
        ),
    ];

    let error = connection
        .execute_in_transaction_checked(&statements, &[1])
        .await
        .unwrap_err();

    assert!(matches!(
        error,
        DriverError::Transaction { statement_index: 1, source } if matches!(*source, DriverError::ConcurrentModification)
    ));
    assert_eq!(
        connection
            .query("SELECT id, payload FROM records ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1), Value::Text("other writer".into())]],
    );
}
