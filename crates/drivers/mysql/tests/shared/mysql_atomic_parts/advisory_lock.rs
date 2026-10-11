use super::*;

async fn assert_query_rows(conn: &dyn Connection, sql: &str, expected: Vec<Vec<Value>>, reason: &str) {
    assert_eq!(conn.query(sql).await.unwrap().rows, expected, "{reason}");
}

async fn expect_failed_batch(conn: &dyn Connection, batch: &[(String, Vec<Value>)], statement_index: usize) {
    let error = conn
        .execute_in_transaction(batch)
        .await
        .expect_err("duplicate key must fail after the advisory-lock side effect");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: index, .. } if index == statement_index),
        "the failed statement index must be preserved, got {error:?}"
    );
}

async fn assert_failed_batch_releases_named_lock(conn: &dyn Connection) {
    const LOCK_NAME: &str = "bookie_b4_failed_batch_release_lock";
    conn.execute("CREATE TABLE rollback_released_lock (id INT PRIMARY KEY, lock_result INT NOT NULL) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("INSERT INTO rollback_released_lock VALUES (1, 0)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE rollback_released_lock_witness (step INT PRIMARY KEY, result INT NOT NULL) ENGINE=MyISAM",
    )
    .await
    .unwrap();
    assert_query_rows(
        conn,
        &format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"),
        vec![vec![Value::Int(1)]],
        "the release test lock must start free",
    )
    .await;

    let batch = vec![
        (
            format!("INSERT INTO rollback_released_lock_witness VALUES (1, GET_LOCK('{LOCK_NAME}', 0))"),
            vec![],
        ),
        (
            format!("INSERT INTO rollback_released_lock_witness VALUES (2, RELEASE_LOCK('{LOCK_NAME}'))"),
            vec![],
        ),
        ("INSERT INTO rollback_released_lock VALUES (1, 0)".into(), vec![]),
    ];
    expect_failed_batch(conn, &batch, 2).await;
    assert_query_rows(
        conn,
        "SELECT id, lock_result FROM rollback_released_lock ORDER BY id",
        vec![vec![Value::Int(1), Value::Int(0)]],
        "the transactional insert must roll back",
    )
    .await;
    assert_query_rows(
        conn,
        "SELECT step, result FROM rollback_released_lock_witness ORDER BY step",
        vec![vec![Value::Int(1), Value::Int(1)], vec![Value::Int(2), Value::Int(1)]],
        "the MyISAM witness records successful acquire and release calls on the batch session",
    )
    .await;
    assert_query_rows(
        conn,
        &format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"),
        vec![vec![Value::Int(1)]],
        "the named lock release survives transaction rollback",
    )
    .await;
}

async fn assert_failed_batch_preserves_named_lock(conn: &dyn Connection) {
    const LOCK_NAME: &str = "bookie_b4_failed_batch_lock";
    conn.execute("CREATE TABLE rollback_named_lock (id INT PRIMARY KEY, lock_result INT NOT NULL) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("INSERT INTO rollback_named_lock VALUES (1, 0)")
        .await
        .unwrap();
    assert_query_rows(
        conn,
        &format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"),
        vec![vec![Value::Int(1)]],
        "the advisory lock must start free",
    )
    .await;

    let batch = vec![
        (
            format!("INSERT INTO rollback_named_lock VALUES (2, GET_LOCK('{LOCK_NAME}', 0))"),
            vec![],
        ),
        ("INSERT INTO rollback_named_lock VALUES (1, 0)".into(), vec![]),
    ];
    expect_failed_batch(conn, &batch, 1).await;
    assert_query_rows(
        conn,
        "SELECT id, lock_result FROM rollback_named_lock ORDER BY id",
        vec![vec![Value::Int(1), Value::Int(0)]],
        "the transactional row must roll back",
    )
    .await;
    assert_query_rows(
        conn,
        &format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"),
        vec![vec![Value::Int(0)]],
        "the named lock survives transaction rollback",
    )
    .await;
    assert_failed_batch_releases_named_lock(conn).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_failed_batch_preserves_named_lock_session_state() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts.clone()).await;
    assert_failed_batch_preserves_named_lock(conn.as_ref()).await;
    conn.close().await.unwrap();
    let observer = connect(opts).await;
    assert_eq!(
        observer
            .query("SELECT IS_FREE_LOCK('bookie_b4_failed_batch_lock')")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "closing the owning pool must release the named lock"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_failed_batch_preserves_named_lock_session_state() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts.clone()).await;
    assert_failed_batch_preserves_named_lock(conn.as_ref()).await;
    conn.close().await.unwrap();
    let observer = connect(opts).await;
    assert_eq!(
        observer
            .query("SELECT IS_FREE_LOCK('bookie_b4_failed_batch_lock')")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "closing the owning pool must release the named lock"
    );
}
