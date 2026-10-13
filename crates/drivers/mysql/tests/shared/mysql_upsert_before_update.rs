use super::*;
use secrecy::ExposeSecret;

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_failed_upsert_keeps_before_update_trigger_effect() {
    let (_container, opts) = start_mysql().await;
    let conn = connect(opts.clone()).await;
    assert_before_update_effect_survives_later_batch_rollback(conn, opts).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_failed_upsert_keeps_before_update_trigger_effect() {
    let (_container, opts) = start_mariadb().await;
    let conn = connect(opts.clone()).await;
    assert_before_update_effect_survives_later_batch_rollback(conn, opts).await;
}

async fn assert_before_update_effect_survives_later_batch_rollback(conn: Box<dyn Connection>, opts: ConnectOptions) {
    conn.execute("CREATE TABLE before_update_upsert_parent (id INT PRIMARY KEY, value INT NOT NULL) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("INSERT INTO before_update_upsert_parent VALUES (1, 10)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE before_update_upsert_myisam_effect (id INT, old_value INT, new_value INT) ENGINE=MyISAM",
    )
    .await
    .unwrap();
    create_before_update_trigger(&opts).await.unwrap();

    let batch = vec![
        (
            "INSERT INTO before_update_upsert_parent VALUES (1, 11) \
             ON DUPLICATE KEY UPDATE value = VALUES(value)"
                .into(),
            vec![],
        ),
        ("INSERT INTO missing_before_update_upsert VALUES (1)".into(), vec![]),
    ];
    crate::mysql_atomic_assertions::assert_failed_batch_preserves_rows(
        conn.as_ref(),
        &batch,
        "SELECT id, value FROM before_update_upsert_parent",
        vec![vec![Value::Int(1), Value::Int(10)]],
        "SELECT id, old_value, new_value FROM before_update_upsert_myisam_effect",
        vec![vec![Value::Int(1), Value::Int(10), Value::Int(11)]],
    )
    .await;
}

async fn create_before_update_trigger(opts: &ConnectOptions) -> Result<(), sqlx::Error> {
    let fixture = sqlx::mysql::MySqlPoolOptions::new()
        .connect_with(
            sqlx::mysql::MySqlConnectOptions::new()
                .host(&opts.host)
                .port(opts.port)
                .username(&opts.username)
                .password(opts.password.expose_secret())
                .database(&opts.database),
        )
        .await?;
    sqlx::raw_sql(
        "CREATE TRIGGER before_update_upsert_parent_before_update BEFORE UPDATE \
         ON before_update_upsert_parent FOR EACH ROW \
         INSERT INTO before_update_upsert_myisam_effect VALUES (OLD.id, OLD.value, NEW.value)",
    )
    .execute(&fixture)
    .await?;
    fixture.close().await;
    Ok(())
}
