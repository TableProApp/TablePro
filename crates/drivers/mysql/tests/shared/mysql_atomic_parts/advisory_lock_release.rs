use super::*;

async fn assert_failed_batch_keeps_named_lock_released(conn: &dyn Connection, observer: &dyn Connection) {
    const LOCK_NAME: &str = "bookie_b4_failed_batch_released_lock";
    conn.execute(
        "CREATE TABLE rollback_named_lock_release (
             id INT PRIMARY KEY,
             acquired INT NOT NULL CHECK (acquired = 1),
             released INT NOT NULL
         ) ENGINE=InnoDB",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO rollback_named_lock_release VALUES (1, 1, 0)")
        .await
        .unwrap();
    assert_eq!(
        observer
            .query(&format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"))
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "the fixture starts with the named lock free"
    );

    let batch = vec![
        (
            format!("INSERT INTO rollback_named_lock_release VALUES (2, GET_LOCK('{LOCK_NAME}', 0), 0)"),
            vec![],
        ),
        (
            format!("UPDATE rollback_named_lock_release SET released = RELEASE_LOCK('{LOCK_NAME}') WHERE id = 2"),
            vec![],
        ),
        (
            "INSERT INTO rollback_named_lock_release VALUES (1, 1, 0)".into(),
            vec![],
        ),
    ];
    let error = conn
        .execute_in_transaction(&batch)
        .await
        .expect_err("the duplicate key must fail after the lock has been released");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: 2, .. }),
        "the failed statement index must be preserved, got {error:?}"
    );
    assert_eq!(
        conn.query("SELECT id, acquired, released FROM rollback_named_lock_release")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1), Value::Int(1), Value::Int(0)]],
        "the transactional insert and lock-result update roll back"
    );
    assert_eq!(
        observer
            .query(&format!("SELECT IS_FREE_LOCK('{LOCK_NAME}')"))
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "rollback must not reacquire a named lock released by the failed batch"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_failed_batch_does_not_restore_a_released_named_lock() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts.clone()).await;
    let observer = connect(opts).await;
    assert_failed_batch_keeps_named_lock_released(conn.as_ref(), observer.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_failed_batch_does_not_restore_a_released_named_lock() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts.clone()).await;
    let observer = connect(opts).await;
    assert_failed_batch_keeps_named_lock_released(conn.as_ref(), observer.as_ref()).await;
}
