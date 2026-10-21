use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn an_edit_on_a_non_unique_sorting_key_is_refused_and_changes_nothing() {
    let (_container, opts) = super::start_clickhouse().await;
    let conn = super::connect(opts).await;
    conn.execute("CREATE TABLE keyed (a Int32, b Int32, v String) ENGINE = MergeTree ORDER BY (a, b) PRIMARY KEY a")
        .await
        .unwrap();
    conn.execute("INSERT INTO keyed VALUES (1, 1, 'x'), (1, 1, 'y'), (1, 2, 'z')")
        .await
        .unwrap();

    let duplicate = (
        "ALTER TABLE `keyed` UPDATE `v` = ? WHERE `a` = ? AND `b` = ?".to_string(),
        vec![Value::Text("edited".into()), Value::Int(1), Value::Int(1)],
    );
    assert!(conn.execute_in_transaction(&[duplicate]).await.is_err());
    let unique = (
        "ALTER TABLE `keyed` UPDATE `v` = ? WHERE `a` = ? AND `b` = ?".to_string(),
        vec![Value::Text("edited".into()), Value::Int(1), Value::Int(2)],
    );
    conn.execute_in_transaction(&[unique]).await.unwrap();

    let rows = conn.query("SELECT v FROM keyed ORDER BY v").await.unwrap().rows;
    assert_eq!(
        rows,
        vec![
            vec![Value::Text("edited".into())],
            vec![Value::Text("x".into())],
            vec![Value::Text("y".into())]
        ]
    );
}
