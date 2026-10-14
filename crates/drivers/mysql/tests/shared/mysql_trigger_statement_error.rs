use super::*;
use secrecy::ExposeSecret;

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_trigger_effect_survives_failure_inside_the_trigger_statement() {
    let (_container, opts) = start_mysql().await;
    assert_trigger_effect_survives_failure_inside_the_trigger_statement(&opts).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_trigger_effect_survives_failure_inside_the_trigger_statement() {
    let (_container, opts) = start_mariadb().await;
    assert_trigger_effect_survives_failure_inside_the_trigger_statement(&opts).await;
}

async fn assert_trigger_effect_survives_failure_inside_the_trigger_statement(opts: &ConnectOptions) {
    let conn = connect(opts.clone()).await;
    conn.execute("CREATE TABLE trigger_failure_parent (id INT PRIMARY KEY) ENGINE=InnoDB")
        .await
        .unwrap();
    conn.execute("CREATE TABLE trigger_failure_witness (id INT PRIMARY KEY) ENGINE=MyISAM")
        .await
        .unwrap();
    conn.execute("INSERT INTO trigger_failure_parent VALUES (1)")
        .await
        .unwrap();

    let fixture = sqlx::mysql::MySqlPoolOptions::new()
        .connect_with(
            sqlx::mysql::MySqlConnectOptions::new()
                .host(&opts.host)
                .port(opts.port)
                .username(&opts.username)
                .password(opts.password.expose_secret())
                .database(&opts.database),
        )
        .await
        .unwrap();
    sqlx::raw_sql(
        "CREATE TRIGGER trigger_failure_after_insert AFTER INSERT ON trigger_failure_parent \
         FOR EACH ROW BEGIN \
             INSERT INTO trigger_failure_witness VALUES (NEW.id); \
             SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'trigger failure'; \
         END",
    )
    .execute(&fixture)
    .await
    .unwrap();
    fixture.close().await;

    let error = conn
        .execute_in_transaction(&[("INSERT INTO trigger_failure_parent VALUES (2)".into(), vec![])])
        .await
        .expect_err("the trigger SIGNAL must fail the statement");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: 0, .. }),
        "the statement error must report its batch index, got {error:?}"
    );
    assert_eq!(
        conn.query("SELECT id FROM trigger_failure_parent ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "the InnoDB parent row is rolled back"
    );
    assert_eq!(
        conn.query("SELECT id FROM trigger_failure_witness ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(2)]],
        "the MyISAM effect issued before SIGNAL remains visible"
    );
    assert_eq!(
        conn.query("SELECT 1").await.unwrap().rows,
        vec![vec![Value::Int(1)]],
        "the pooled connection remains usable after statement rollback"
    );
}
