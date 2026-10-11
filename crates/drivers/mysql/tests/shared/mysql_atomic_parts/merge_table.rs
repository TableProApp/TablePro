use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_failed_batch_merge_table_insert_survives_rollback() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE merge_backing (id INT NOT NULL) ENGINE=MyISAM")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE merge_effects (id INT NOT NULL) \
         ENGINE=MRG_MyISAM UNION=(merge_backing) INSERT_METHOD=LAST",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO merge_effects VALUES (1)").await.unwrap();

    let batch = vec![
        ("INSERT INTO merge_effects VALUES (2)".into(), vec![]),
        ("INSERT INTO missing_merge_effects VALUES (99)".into(), vec![]),
    ];
    let error = conn
        .execute_in_transaction(&batch)
        .await
        .expect_err("the missing table must fail after the MERGE write");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: 1, .. }),
        "MERGE failure must identify statement 1, got {error:?}"
    );
    assert_eq!(
        conn.query("SELECT id FROM merge_backing ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)], vec![Value::Int(2)]],
        "the underlying MyISAM write through MERGE survives rollback"
    );
}
