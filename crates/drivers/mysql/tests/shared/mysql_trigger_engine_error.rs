use super::*;
use secrecy::ExposeSecret;

const MYSQL_ENGINES: [(&str, &str); 3] = [("memory", "MEMORY"), ("csv", "CSV"), ("archive", "ARCHIVE")];
const MARIADB_ENGINES: [(&str, &str); 3] = [("memory", "MEMORY"), ("csv", "CSV"), ("aria", "Aria TRANSACTIONAL=0")];

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_trigger_effects_survive_a_signal_across_nontransactional_engines() {
    let (_container, opts) = start_mysql().await;
    assert_trigger_effects_survive_a_signal(&opts, &MYSQL_ENGINES).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_trigger_effects_survive_a_signal_across_nontransactional_engines() {
    let (_container, opts) = start_mariadb().await;
    assert_trigger_effects_survive_a_signal(&opts, &MARIADB_ENGINES).await;
}

async fn assert_trigger_effects_survive_a_signal(opts: &ConnectOptions, engines: &[(&str, &str)]) {
    let conn = connect(opts.clone()).await;
    conn.execute("CREATE TABLE engine_error_parent (id INT PRIMARY KEY) ENGINE=InnoDB")
        .await
        .unwrap();
    for (name, engine) in engines {
        conn.execute(&format!(
            "CREATE TABLE engine_error_{name} (id INT NOT NULL) ENGINE={engine}"
        ))
        .await
        .unwrap();
    }
    conn.execute("INSERT INTO engine_error_parent VALUES (1)")
        .await
        .unwrap();
    create_signal_trigger(opts, engines).await;

    let error = conn
        .execute_in_transaction(&[("INSERT INTO engine_error_parent VALUES (2)".into(), vec![])])
        .await
        .expect_err("the trigger SIGNAL must fail the statement");
    assert!(
        matches!(error, DriverError::Transaction { statement_index: 0, .. }),
        "the statement error must report its batch index, got {error:?}"
    );
    assert_eq!(
        conn.query("SELECT id FROM engine_error_parent ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "the InnoDB parent row is rolled back"
    );
    for (name, _) in engines {
        assert_eq!(
            conn.query(&format!("SELECT id FROM engine_error_{name}"))
                .await
                .unwrap()
                .rows,
            vec![vec![Value::Int(2)]],
            "the {name} trigger effect issued before SIGNAL remains visible"
        );
    }
    assert_eq!(conn.query("SELECT 1").await.unwrap().rows, vec![vec![Value::Int(1)]]);
}

async fn create_signal_trigger(opts: &ConnectOptions, engines: &[(&str, &str)]) {
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
    let engine_writes = engines
        .iter()
        .map(|(name, _)| format!("INSERT INTO engine_error_{name} VALUES (NEW.id);"))
        .collect::<Vec<_>>()
        .join(" ");
    let trigger = format!(
        "CREATE TRIGGER engine_error_after_insert AFTER INSERT ON engine_error_parent \
         FOR EACH ROW BEGIN {engine_writes} \
         SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'trigger failure'; END"
    );
    sqlx::raw_sql(sqlx::AssertSqlSafe(trigger))
        .execute(&fixture)
        .await
        .unwrap();
    fixture.close().await;
}
