#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::str::FromStr;

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use rust_decimal::Decimal;
use serde_json::json;

use drivers_mysql::MysqlDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, OperationControl, Value};
use testcontainers::ImageExt;
use testcontainers::core::IntoContainerPort;
use testcontainers_modules::mysql::Mysql;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

#[path = "../../shared/server_restart.rs"]
mod server_restart;

#[path = "support/disconnection.rs"]
mod disconnection;

#[path = "support/shared_container.rs"]
mod shared_container;

#[path = "support/read_only_session.rs"]
mod read_only_session;

#[path = "support/result_charset.rs"]
mod result_charset;

#[path = "shared/mysql_atomic.rs"]
mod mysql_atomic;

#[path = "shared/mysql_user_variable.rs"]
mod mysql_user_variable;

#[path = "../../shared/connect_refusal.rs"]
mod connect_refusal;

#[tokio::test]
async fn an_unavailable_mysql_server_is_classified_as_connection_refused() {
    connect_refusal::assert_connection_refused(&MysqlDriver)
        .await
        .expect("MySQL setup refusal remains distinct from established disconnect");
}

async fn start_mysql() -> (shared_container::TestDatabase, ConnectOptions) {
    shared_container::start_mysql().await
}

async fn start_mariadb() -> (shared_container::MariaDbTestDatabase, ConnectOptions) {
    shared_container::start_mariadb().await
}

async fn connect(opts: ConnectOptions) -> Box<dyn Connection> {
    MysqlDriver.connect(opts).await.expect("connect")
}

#[tokio::test]
#[ignore = "requires docker"]
async fn server_terminated_query_reports_disconnection_and_pool_recovers() {
    let (_container, opts) = start_mysql().await;
    let connection: std::sync::Arc<dyn Connection> = MysqlDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let tag = "tablepro_mysql_backend_termination";
    let running = connection.clone();
    let task = tokio::spawn(async move { running.query(&format!("SELECT SLEEP(30) /* {tag} */")).await });

    let mut connection_id = None;
    for _ in 0..100 {
        let result = observer
            .query(&format!(
                "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%{tag}%' AND ID <> CONNECTION_ID()"
            ))
            .await
            .expect("inspect active query");
        connection_id = result.rows.first().and_then(|row| match row.first() {
            Some(Value::Int(id)) => Some(*id),
            _ => None,
        });
        if connection_id.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let connection_id = connection_id.expect("tagged query must reach MySQL");
    observer
        .execute(&format!("KILL CONNECTION {connection_id}"))
        .await
        .expect("terminate active query connection");

    let error = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .expect("terminated query must not hang")
        .expect("query task")
        .expect_err("a terminated query must not return success");
    assert!(
        matches!(error, DriverError::Disconnected),
        "a terminated MySQL connection must be reported as disconnected, got {error:?}"
    );

    let recovered = connection
        .query("SELECT 1")
        .await
        .expect("pool must recover on a new connection");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_disconnected_session_is_retired_without_affecting_the_shared_pool() {
    let (_container, opts) = start_mysql().await;
    let connection = MysqlDriver.connect(opts.clone()).await.expect("connect");
    let observer = connect(opts).await;
    let mut session = connection.open_session().await.expect("open session");
    let tag = "tablepro_mysql_session_backend_termination";
    let query = tokio::spawn(async move {
        let result = session
            .query_params_controlled(
                &format!("SELECT SLEEP(30) /* {tag} */"),
                &[],
                &OperationControl::with_timeout(std::time::Duration::from_secs(40)),
            )
            .await;
        (session, result)
    });

    let mut connection_id = None;
    for _ in 0..100 {
        let result = observer
            .query(&format!(
                "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%{tag}%' AND ID <> CONNECTION_ID()"
            ))
            .await
            .expect("inspect active session query");
        connection_id = result.rows.first().and_then(|row| match row.first() {
            Some(Value::Int(id)) => Some(*id),
            _ => None,
        });
        if connection_id.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let connection_id = connection_id.expect("tagged session query must reach MySQL");
    observer
        .execute(&format!("KILL CONNECTION {connection_id}"))
        .await
        .expect("terminate session backend");

    let (mut session, result) = tokio::time::timeout(std::time::Duration::from_secs(5), query)
        .await
        .expect("terminated session query must not hang")
        .expect("session query task");
    let error = result.expect_err("a terminated session query must not succeed");
    assert!(matches!(error, DriverError::Disconnected), "{error:?}");
    assert!(!session.is_usable(), "a lost session must be retired");
    assert!(matches!(
        session
            .query_params_controlled(
                "SELECT 1",
                &[],
                &OperationControl::with_timeout(std::time::Duration::from_secs(5)),
            )
            .await,
        Err(DriverError::Internal(_))
    ));
    assert_eq!(
        connection.query("SELECT 1").await.unwrap().rows,
        vec![vec![Value::Int(1)]]
    );
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_session_detects_backend_loss_before_the_next_statement() {
    let (_container, opts) = start_mysql().await;
    let connection = MysqlDriver.connect(opts.clone()).await.expect("connect");
    let observer = connect(opts).await;
    let mut session = connection.open_session().await.expect("open session");
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(5));
    let result = session
        .query_params_controlled("SELECT CONNECTION_ID()", &[], &control)
        .await
        .expect("read session connection id");
    let connection_id = match result.rows[0][0] {
        Value::Int(id) => id,
        ref value => panic!("unexpected MySQL connection id: {value:?}"),
    };
    observer
        .execute(&format!("KILL CONNECTION {connection_id}"))
        .await
        .expect("terminate idle session backend");

    let error = session
        .query_params_controlled("SELECT 1", &[], &control)
        .await
        .expect_err("a statement after backend loss must not masquerade as the old session");
    assert!(matches!(error, DriverError::Disconnected), "{error:?}");
    assert!(!session.is_usable(), "the lost session must be retired");
    assert_eq!(
        connection.query("SELECT 1").await.unwrap().rows,
        vec![vec![Value::Int(1)]]
    );
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn backend_loss_during_row_stream_fails_the_whole_query_as_disconnected() {
    let (_container, opts) = start_mysql().await;
    let connection: std::sync::Arc<dyn Connection> = MysqlDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let tag = "tablepro_mysql_midstream_backend_termination";
    let running = connection.clone();
    let task = tokio::spawn(async move {
        running
            .query(&format!(
                "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100) \
                 SELECT n, SLEEP(0.05) FROM seq /* {tag} */"
            ))
            .await
    });

    let mut connection_id = None;
    for _ in 0..100 {
        let result = observer
            .query(&format!(
                "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%{tag}%' AND ID <> CONNECTION_ID()"
            ))
            .await
            .expect("inspect active streaming query");
        connection_id = result.rows.first().and_then(|row| match row.first() {
            Some(Value::Int(id)) => Some(*id),
            _ => None,
        });
        if connection_id.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let connection_id = connection_id.expect("tagged streaming query must reach MySQL");
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    observer
        .execute(&format!("KILL CONNECTION {connection_id}"))
        .await
        .expect("terminate streaming query connection");

    let error = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .expect("interrupted row stream must not hang")
        .expect("query task")
        .expect_err("interrupted row stream must not return a partial result");
    assert!(
        matches!(error, DriverError::Disconnected),
        "mid-stream backend loss must be reported as disconnected, got {error:?}"
    );
    let recovered = connection
        .query("SELECT 1")
        .await
        .expect("pool recovers after stream loss");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_restarted_mysql_server_restores_the_existing_pool() {
    let port_probe = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("reserve test port");
    let host_port = port_probe.local_addr().expect("test port address").port();
    drop(port_probe);
    let container = Mysql::default()
        .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
        .with_cmd(["--default-authentication-plugin=mysql_native_password"])
        .with_mapped_port(host_port, 3306.tcp())
        .start()
        .await
        .expect("start MySQL on a stable host port");
    let opts = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: host_port,
        database: "test".into(),
        username: "root".into(),
        password: secrecy::SecretString::new("tablepro_test".to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    let connection: std::sync::Arc<dyn Connection> = MysqlDriver.connect(opts).await.expect("connect").into();
    let initial = connection.query("SELECT 1").await.expect("initial query");
    assert_eq!(initial.rows, vec![vec![Value::Int(1)]]);

    container.stop().await.expect("stop MySQL server");
    let error = connection
        .query("SELECT 1")
        .await
        .expect_err("the stopped server must break the established operation");
    assert!(
        matches!(error, DriverError::Disconnected),
        "server loss on an established MySQL pool connection must be Disconnected, got {error:?}"
    );

    container.start().await.expect("restart MySQL server");
    let recovered = server_restart::retry_operation("MySQL", || {
        let connection = connection.clone();
        async move { connection.query("SELECT 1").await }
    })
    .await
    .expect("the existing MySQL pool reconnects after server restart");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_collation_survives_a_nullability_change() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE collated (id int PRIMARY KEY, label varchar(40) COLLATE utf8mb4_bin NULL)")
        .await
        .unwrap();

    let columns = conn.fetch_columns(None, "collated").await.unwrap();
    let label = columns.iter().find(|c| c.name == "label").unwrap().clone();
    assert_eq!(label.collation.as_deref(), Some("utf8mb4_bin"));

    let mut draft = tablepro_core::sql_ddl::DraftColumn::from_info(label);
    draft.nullable = false;
    for statement in tablepro_core::sql_ddl::build_alter_column("mysql", None, "collated", &draft).unwrap() {
        conn.execute(&statement).await.unwrap();
    }

    let altered = conn.fetch_columns(None, "collated").await.unwrap();
    let label = altered.iter().find(|c| c.name == "label").unwrap();
    assert!(!label.nullable);
    assert_eq!(label.collation.as_deref(), Some("utf8mb4_bin"));
}

async fn session_value(session: &mut Box<dyn tablepro_core::Session>, sql: &str) -> Value {
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let result = session.query_params_controlled(sql, &[], &control).await.unwrap();
    result.rows[0][0].clone()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_session_keeps_variables_temp_tables_and_its_transaction_between_statements() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE ledger (id int)").await.unwrap();
    let mut session = conn.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));

    for sql in [
        "SET @kept = 41",
        "CREATE TEMPORARY TABLE scratch (n int)",
        "INSERT INTO scratch VALUES (7)",
    ] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(session_value(&mut session, "SELECT @kept + 1").await, Value::Int(42));
    assert_eq!(
        session_value(&mut session, "SELECT n FROM scratch").await,
        Value::Int(7)
    );
    for sql in ["START TRANSACTION", "INSERT INTO ledger VALUES (1)", "ROLLBACK"] {
        session.query_params_controlled(sql, &[], &control).await.unwrap();
    }
    assert_eq!(
        session_value(&mut session, "SELECT COUNT(*) FROM ledger").await,
        Value::Int(0)
    );
    session.close().await.unwrap();

    let mut sessions = Vec::new();
    for _ in 0..6 {
        sessions.push(conn.open_session().await.unwrap());
    }
    assert_eq!(conn.query("SELECT 1").await.unwrap().rows, vec![vec![Value::Int(1)]]);
    for session in sessions {
        session.close().await.unwrap();
    }
}

async fn tagged_query_is_active(connection: &dyn Connection, tag: &str) -> bool {
    let sql = format!(
        "SELECT count(*) FROM information_schema.processlist \
         WHERE info LIKE '%{tag}%' AND info NOT LIKE '%processlist%'"
    );
    let result = connection.query(&sql).await.expect("inspect the processlist");
    matches!(result.rows.first().and_then(|row| row.first()), Some(Value::Int(count)) if *count > 0)
}

/// MySQL's `SLEEP()` returns 1 when interrupted instead of raising an
/// error, so it cannot prove a cancellation reached the server. A
/// cross join with a non-indexable predicate is interruptible and
/// reports `ER_QUERY_INTERRUPTED`, which is the outcome under test.
async fn create_long_query_source(connection: &dyn Connection) {
    connection
        .execute("CREATE TABLE cancel_probe (x int NOT NULL)")
        .await
        .expect("create the probe table");
    connection
        .execute(
            "INSERT INTO cancel_probe (x) \
             WITH RECURSIVE s AS (SELECT 1 AS x UNION ALL SELECT x + 1 FROM s WHERE x < 999) SELECT x FROM s",
        )
        .await
        .expect("fill the probe table");
}

fn long_query(tag: &str) -> String {
    format!(
        "SELECT count(*) FROM cancel_probe a, cancel_probe b, cancel_probe c \
         WHERE a.x + b.x + c.x > 0 /* {tag} */"
    )
}

async fn wait_for_tagged_query(connection: &dyn Connection, tag: &str, active: bool) {
    for _ in 0..200 {
        if tagged_query_is_active(connection, tag).await == active {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("query tag {tag} did not reach active={active}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn connect_list_tables_and_pk_detection() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE pk_demo (
            id int AUTO_INCREMENT PRIMARY KEY,
            name varchar(255) NOT NULL,
            note text NULL
        )",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO pk_demo (name, note) VALUES ('a', NULL), ('b', 'second')")
        .await
        .unwrap();

    let tables = conn.list_tables().await.unwrap();
    assert!(tables.iter().any(|t| t.name == "pk_demo"));

    let cols = conn.fetch_columns(None, "pk_demo").await.unwrap();
    assert_eq!(cols.len(), 3);
    let id_col = cols.iter().find(|c| c.name == "id").unwrap();
    assert!(id_col.primary_key, "id must be detected as primary key");
    assert!(!id_col.nullable);
    let note_col = cols.iter().find(|c| c.name == "note").unwrap();
    assert!(!note_col.primary_key);
    assert!(note_col.nullable);

    let result = conn.fetch_rows(None, "pk_demo", 0, 100).await.unwrap();
    assert_eq!(result.rows.len(), 2);
    assert!(!result.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_roundtrip_all_types() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;

    conn.execute(
        "CREATE TABLE roundtrip (
            id int AUTO_INCREMENT PRIMARY KEY,
            b tinyint(1),
            i_small smallint,
            i_medium mediumint,
            i_big bigint,
            f_single float,
            f_double double,
            num decimal(20,5),
            t text,
            bytes varbinary(64),
            d date,
            tm time,
            dt datetime,
            ts timestamp NULL,
            u varchar(36),
            j json,
            nullable_text text NULL
        )",
    )
    .await
    .unwrap();

    let date = NaiveDate::from_ymd_opt(2024, 6, 15).unwrap();
    let time = NaiveTime::from_hms_opt(13, 45, 30).unwrap();
    let dt = NaiveDateTime::new(date, time);
    let tz: DateTime<Utc> = Utc.with_ymd_and_hms(2024, 6, 15, 13, 45, 30).unwrap();
    let uuid = uuid::Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    let dec = Decimal::from_str("12345.67890").unwrap();
    let json_val = json!({"k": [1, 2, 3], "nested": {"flag": true}});

    let params = vec![
        Value::Bool(true),
        Value::Int(123),
        Value::Int(456_789),
        Value::Int(9_000_000_000_000_000_000),
        Value::Float(1.5_f64),
        Value::Float(std::f64::consts::PI),
        Value::Decimal(dec),
        Value::Text("hello\nworld".into()),
        Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]),
        Value::Date(date),
        Value::Time(time),
        Value::DateTime(dt),
        Value::TimestampTz(tz),
        Value::Uuid(uuid),
        Value::Json(json_val.clone()),
        Value::Null,
    ];

    let res = conn
        .execute_params(
            "INSERT INTO roundtrip
             (b, i_small, i_medium, i_big, f_single, f_double, num, t, bytes, d, tm, dt, ts, u, j, nullable_text)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            &params,
        )
        .await
        .unwrap();
    assert_eq!(res.rows_affected, 1);

    let q = conn
        .query(
            "SELECT b, i_small, i_medium, i_big, f_single, f_double, num, t, bytes, d, tm, dt, ts, u, j, nullable_text
             FROM roundtrip ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(q.rows.len(), 1);
    let row = &q.rows[0];

    match &row[0] {
        Value::Bool(true) => {}
        Value::Int(1) => {}
        v => panic!("expected tinyint(1) -> Bool(true) or Int(1), got {v:?}"),
    }
    assert!(matches!(row[1], Value::Int(123)));
    assert!(matches!(row[2], Value::Int(456_789)));
    assert!(matches!(row[3], Value::Int(9_000_000_000_000_000_000)));
    match &row[4] {
        Value::Float(f) => assert!((*f - 1.5).abs() < 1e-5),
        v => panic!("expected float, got {v:?}"),
    }
    match &row[5] {
        Value::Float(f) => assert!((*f - std::f64::consts::PI).abs() < 1e-9),
        v => panic!("expected double, got {v:?}"),
    }
    match &row[6] {
        Value::Decimal(d) => assert_eq!(d.to_string(), "12345.67890"),
        v => panic!("expected decimal, got {v:?}"),
    }
    assert_eq!(row[7], Value::Text("hello\nworld".into()));
    assert_eq!(row[8], Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]));
    assert_eq!(row[9], Value::Date(date));
    assert_eq!(row[10], Value::Time(time));
    assert_eq!(row[11], Value::DateTime(dt));
    assert_eq!(row[12], Value::TimestampTz(tz));
    match &row[13] {
        Value::Text(s) => assert_eq!(s, "550e8400-e29b-41d4-a716-446655440000"),
        v => panic!("expected uuid as text, got {v:?}"),
    }
    match &row[14] {
        Value::Json(v) => assert_eq!(v, &json_val),
        v => panic!("expected json, got {v:?}"),
    }
    assert_eq!(row[15], Value::Null);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pagination_and_truncated_flag() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE big (i int PRIMARY KEY)").await.unwrap();
    let mut sql = String::from("INSERT INTO big (i) VALUES ");
    for i in 0..50 {
        if i > 0 {
            sql.push(',');
        }
        sql.push_str(&format!("({i})"));
    }
    conn.execute(&sql).await.unwrap();

    let page = conn.fetch_rows(None, "big", 10, 5).await.unwrap();
    assert_eq!(page.rows.len(), 5);
    let firsts: Vec<i64> = page
        .rows
        .iter()
        .map(|r| match r[0] {
            Value::Int(i) => i,
            _ => panic!(),
        })
        .collect();
    assert_eq!(firsts, vec![10, 11, 12, 13, 14]);

    let q = conn.query("SELECT i FROM big ORDER BY i").await.unwrap();
    assert_eq!(q.rows.len(), 50);
    assert!(!q.truncated);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_decimal_value_past_rust_decimals_range_keeps_its_digits() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE big_decimal (v DECIMAL(65,0))")
        .await
        .unwrap();
    let digits = "1".repeat(65);
    conn.execute(&format!("INSERT INTO big_decimal (v) VALUES ({digits})"))
        .await
        .unwrap();

    let result = conn.query("SELECT v FROM big_decimal").await.unwrap();
    assert_eq!(result.rows, vec![vec![Value::Text(digits)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_bigint_unsigned_value_past_i64_max_keeps_its_digits() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE big_unsigned (v BIGINT UNSIGNED)")
        .await
        .unwrap();
    conn.execute("INSERT INTO big_unsigned (v) VALUES (18446744073709551615)")
        .await
        .unwrap();

    let result = conn.query("SELECT v FROM big_unsigned").await.unwrap();
    assert_eq!(result.rows, vec![vec![Value::Text("18446744073709551615".into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn bad_sql_returns_query_error() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;

    let err = conn.query("SELECT * FROM no_such_table").await.unwrap_err();
    let msg = format!("{err}").to_lowercase();
    assert!(
        msg.contains("no_such_table") || msg.contains("doesn't exist") || msg.contains("table"),
        "expected error to mention missing table, got: {msg}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_driver_declares_server_side_cancellation() {
    let (_container, opts) = start_mysql().await;
    let connection = connect(opts).await;
    assert!(connection.supports_server_cancellation());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancelled_query_is_killed_on_the_server_and_the_pool_stays_usable() {
    let (_container, opts) = start_mysql().await;
    let connection: std::sync::Arc<dyn Connection> = MysqlDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let token = tokio_util::sync::CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    create_long_query_source(observer.as_ref()).await;
    let sql = long_query("tablepro_mysql_cancel");
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move { operation_connection.query_controlled(&sql, &control).await });

    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_cancel", true).await;
    token.cancel();
    let error = task
        .await
        .expect("query task")
        .expect_err("the query must be cancelled");
    assert!(matches!(error, DriverError::Cancelled), "unexpected error: {error:?}");
    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_cancel", false).await;

    let result = connection.query("SELECT 1").await.expect("the pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_timed_out_write_is_killed_on_the_server_and_reports_a_timeout() {
    let (_container, opts) = start_mysql().await;
    let connection: std::sync::Arc<dyn Connection> = MysqlDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    create_long_query_source(observer.as_ref()).await;
    connection
        .execute("CREATE TABLE cancel_sink (total bigint)")
        .await
        .expect("create the sink table");

    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
    let control = OperationControl::new(tokio_util::sync::CancellationToken::new(), Some(deadline));
    let sql = format!(
        "INSERT INTO cancel_sink (total) {}",
        long_query("tablepro_mysql_timeout")
    );
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move { operation_connection.execute_controlled(&sql, &control).await });

    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_timeout", true).await;
    let error = task.await.expect("execute task").expect_err("the write must time out");
    assert!(matches!(error, DriverError::TimedOut), "unexpected error: {error:?}");
    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_timeout", false).await;

    let rows = connection
        .query("SELECT count(*) FROM cancel_sink")
        .await
        .expect("the pool remains usable");
    assert_eq!(
        rows.rows,
        vec![vec![Value::Int(0)]],
        "the aborted insert must not commit"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancelled_session_query_is_killed_on_the_server_and_the_session_stays_usable() {
    let (_container, opts) = start_mysql().await;
    let connection = connect(opts.clone()).await;
    let observer = connect(opts).await;
    create_long_query_source(observer.as_ref()).await;

    let session = connection.open_session().await.expect("open session");
    let token = tokio_util::sync::CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let sql = long_query("tablepro_mysql_session_cancel");
    let task = tokio::spawn(async move {
        let mut session = session;
        let result = session.query_params_controlled(&sql, &[], &control).await;
        (session, result)
    });

    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_session_cancel", true).await;
    token.cancel();
    let (mut session, result) = task.await.expect("session task");
    assert!(
        matches!(result, Err(DriverError::Cancelled)),
        "unexpected error: {result:?}"
    );
    wait_for_tagged_query(observer.as_ref(), "tablepro_mysql_session_cancel", false).await;

    assert!(
        session.is_usable(),
        "the session must stay usable after a confirmed cancel"
    );
    assert_eq!(session_value(&mut session, "SELECT 1").await, Value::Int(1));
    session.close().await.expect("close the session");
}

/// A value ending in a backslash used to break out of the literal that
/// "Copy row as INSERT" produced, because MySQL treats a backslash as an
/// escape inside a string. MySQL 8.1 evaluated the unescaped form as the
/// expression `'x\'' OR 1=1` and returned 1 instead of storing the text.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_copied_insert_survives_a_value_that_could_escape_its_literal() {
    let (_c, opts) = start_mysql().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TABLE copy_probe (id int PRIMARY KEY, note varchar(200))")
        .await
        .expect("create the probe table");

    let payload = "x\\' OR 1=1 -- ";
    connection
        .execute_params(
            "INSERT INTO copy_probe (id, note) VALUES (?, ?)",
            &[Value::Int(1), Value::Text(payload.into())],
        )
        .await
        .expect("store the payload as data");

    let columns = connection.fetch_columns(None, "copy_probe").await.expect("columns");
    let clause = tablepro_core::export::render_in_clause("mysql", &[vec![Value::Text(payload.into())]], 0);
    let matching = connection
        .query(&format!("SELECT note FROM copy_probe WHERE note IN {}", clause.sql))
        .await
        .unwrap();
    assert_eq!(matching.rows, vec![vec![Value::Text(payload.into())]]);
    let loaded = connection
        .query("SELECT id, note FROM copy_probe WHERE id = 1")
        .await
        .expect("read the row back");
    let row: Vec<Value> = loaded.rows[0]
        .iter()
        .cloned()
        .map(|value| match value {
            Value::Int(id) => Value::Int(id + 1),
            other => other,
        })
        .collect();

    let sql = tablepro_core::sql_literal::build_insert_literal("mysql", None, "copy_probe", &columns, &row)
        .expect("render the insert");
    connection.execute(&sql).await.expect("the copied insert must execute");

    let after = connection
        .query("SELECT note FROM copy_probe WHERE id = 2")
        .await
        .expect("read the copied row");
    assert_eq!(
        after.rows,
        vec![vec![Value::Text(payload.into())]],
        "the copied row must hold the same text, not the result of evaluating it"
    );
    let count = connection
        .query("SELECT count(*) FROM copy_probe")
        .await
        .expect("count the rows");
    assert_eq!(
        count.rows,
        vec![vec![Value::Int(2)]],
        "the insert must add exactly one row"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_comment_round_trips_and_an_uncommented_column_reads_as_none() {
    let (_container, opts) = start_mysql().await;
    let connection = connect(opts).await;
    connection
        .execute(
            "CREATE TABLE comment_demo (\
                id int NOT NULL, \
                label varchar(64) COMMENT 'what the row is called')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "comment_demo").await.unwrap();
    let id = columns.iter().find(|c| c.name == "id").unwrap();
    let label = columns.iter().find(|c| c.name == "label").unwrap();
    assert_eq!(label.comment.as_deref(), Some("what the row is called"));
    assert_eq!(
        id.comment, None,
        "an uncommented column reports the engine's empty string as no comment"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_column_comment_backslash_literals_depend_on_sql_mode() {
    let (_container, opts) = start_mysql().await;
    let connection = connect(opts).await;
    for (table, sql_mode, expected) in [
        ("comment_mode_default", "", r"path\to\value"),
        ("comment_mode_no_backslash", "NO_BACKSLASH_ESCAPES", r"path\\to\\value"),
    ] {
        let mut session = connection.open_session().await.unwrap();
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        for sql in [
            format!("SET SESSION sql_mode = '{sql_mode}'"),
            format!("CREATE TABLE {table} (label varchar(64) COMMENT 'path\\\\to\\\\value')"),
        ] {
            session
                .query_params_controlled(&sql, &[], &control)
                .await
                .unwrap_or_else(|error| panic!("statement in SQL mode {sql_mode:?}: {error:?}"));
        }
        session.close().await.unwrap();
        let columns = connection.fetch_columns(None, table).await.unwrap();
        let label = columns.iter().find(|column| column.name == "label").unwrap();
        assert_eq!(
            label.comment.as_deref().unwrap().as_bytes(),
            expected.as_bytes(),
            "SQL mode {sql_mode:?}; actual bytes {:?}",
            label.comment.as_deref().unwrap().as_bytes()
        );
    }
}

async fn column_default(conn: &dyn Connection, table: &str, column: &str) -> Option<String> {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    columns.into_iter().find(|c| c.name == column).unwrap().default_value
}

type KeptDefaults = [(&'static str, Option<&'static str>); 7];

const KEPT_DEFAULTS: KeptDefaults = [
    ("bare", None),
    ("explicit_null", None),
    ("blank", Some("''")),
    ("word", Some("'it''s'")),
    ("digits", Some("'007'")),
    ("amount", Some("0")),
    ("stamped", Some("CURRENT_TIMESTAMP")),
];

#[tokio::test]
#[ignore = "requires docker"]
async fn a_nullability_change_keeps_no_default_null_empty_and_literal_defaults_apart() {
    let (_c, opts) = start_mysql().await;
    assert_defaults_survive_a_nullability_change(connect(opts).await, KEPT_DEFAULTS).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_mariadb_default_is_reported_as_its_clause_without_quoting_it_twice() {
    let (_container, opts) = start_mariadb().await;
    let mut expected = KEPT_DEFAULTS;
    expected[6] = ("stamped", Some("current_timestamp()"));
    assert_defaults_survive_a_nullability_change(connect(opts).await, expected).await;
}

async fn assert_defaults_survive_a_nullability_change(conn: Box<dyn Connection>, expected: KeptDefaults) {
    conn.execute(
        "CREATE TABLE defaults_kept (id int PRIMARY KEY, \
         bare varchar(20) NULL, \
         explicit_null varchar(20) NULL DEFAULT NULL, \
         blank varchar(20) NULL DEFAULT '', \
         word varchar(20) NULL DEFAULT 'it''s', \
         digits varchar(20) NULL DEFAULT '007', \
         amount int NULL DEFAULT 0, \
         stamped timestamp NULL DEFAULT CURRENT_TIMESTAMP)",
    )
    .await
    .unwrap();
    for (name, default) in expected {
        assert_eq!(
            column_default(conn.as_ref(), "defaults_kept", name).await.as_deref(),
            default,
            "{name}"
        );
    }

    let columns = conn.fetch_columns(None, "defaults_kept").await.unwrap();
    for info in columns.into_iter().filter(|c| c.name != "id") {
        let mut draft = tablepro_core::sql_ddl::DraftColumn::from_info(info);
        draft.nullable = false;
        for statement in tablepro_core::sql_ddl::build_alter_column("mysql", None, "defaults_kept", &draft).unwrap() {
            conn.execute(&statement).await.unwrap();
        }
    }

    for (name, default) in expected {
        assert_eq!(
            column_default(conn.as_ref(), "defaults_kept", name).await.as_deref(),
            default,
            "{name}"
        );
    }
    conn.execute("INSERT INTO defaults_kept (id, bare, explicit_null) VALUES (1, 'a', 'b')")
        .await
        .unwrap();
    let row = conn
        .query("SELECT blank, word, digits, amount FROM defaults_kept WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(
        row.rows[0],
        vec![
            Value::Text(String::new()),
            Value::Text("it's".into()),
            Value::Text("007".into()),
            Value::Int(0),
        ]
    );
}

async fn notes_in(conn: &dyn Connection, table: &str) -> Vec<String> {
    let rows = conn.query(&format!("SELECT note FROM {table}")).await.unwrap();
    let mut notes: Vec<String> = rows
        .rows
        .iter()
        .map(|row| match &row[0] {
            Value::Text(text) => text.clone(),
            other => panic!("note must be text, got {other:?}"),
        })
        .collect();
    notes.sort();
    notes
}

async fn grid_edits_and_deletes_only_the_keyed_row(conn: &dyn Connection, driver_id: &str, table: &str) {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    let note = columns.iter().position(|c| c.name == "note").unwrap();
    let rows = conn.fetch_rows(None, table, 0, 10).await.unwrap();
    let target = rows
        .rows
        .iter()
        .find(|row| row[note] == Value::Text("target".into()))
        .unwrap();
    let pk_values: Vec<Value> = columns
        .iter()
        .zip(target)
        .filter(|(column, _)| column.primary_key)
        .map(|(_, value)| value.clone())
        .collect();
    assert!(!pk_values.is_empty(), "{table} must report its primary key");
    let before = notes_in(conn, table).await;
    let others: Vec<String> = before.iter().filter(|n| *n != "target").cloned().collect();

    let update = tablepro_core::sql_dialect::build_keyed_update(
        driver_id,
        None,
        table,
        &columns,
        &[(note, Value::Text("edited".into()))],
        &pk_values,
    )
    .unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[update]).await.unwrap(),
        vec![1],
        "{table} update"
    );
    let mut expected = others.clone();
    expected.insert(0, "edited".to_string());
    assert_eq!(
        notes_in(conn, table).await,
        expected,
        "{table} update touched only the keyed row"
    );

    let delete = tablepro_core::sql_dialect::build_keyed_delete(driver_id, None, table, &columns, &pk_values).unwrap();
    assert_eq!(
        conn.execute_in_transaction(&[delete]).await.unwrap(),
        vec![1],
        "{table} delete"
    );
    assert_eq!(
        notes_in(conn, table).await,
        others,
        "{table} delete removed only the keyed row"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn grid_row_edits_find_rows_by_uuid_composite_and_wide_bigint_keys() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    for sql in [
        "CREATE TABLE keyed_uuid_text (id char(36) PRIMARY KEY, note varchar(20))",
        "INSERT INTO keyed_uuid_text VALUES ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b', 'target'), \
         ('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5c', 'other')",
        "CREATE TABLE keyed_uuid_binary (id binary(16) PRIMARY KEY, note varchar(20))",
        "INSERT INTO keyed_uuid_binary VALUES (UUID_TO_BIN('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b'), 'target'), \
         (UUID_TO_BIN('6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5c'), 'other')",
        "CREATE TABLE keyed_composite (tenant int, code varchar(10), note varchar(20), PRIMARY KEY (tenant, code))",
        "INSERT INTO keyed_composite VALUES (1, 'a', 'target'), (1, 'b', 'other'), (2, 'a', 'other')",
        "CREATE TABLE keyed_bigint (id bigint PRIMARY KEY, note varchar(20))",
        "INSERT INTO keyed_bigint VALUES (9007199254740993, 'target'), (9007199254740992, 'other')",
        "CREATE TABLE keyed_unsigned (id bigint unsigned PRIMARY KEY, note varchar(20))",
        "INSERT INTO keyed_unsigned VALUES (18446744073709551615, 'target'), (18446744073709551614, 'other')",
    ] {
        conn.execute(sql).await.unwrap();
    }
    for table in [
        "keyed_uuid_text",
        "keyed_uuid_binary",
        "keyed_composite",
        "keyed_bigint",
        "keyed_unsigned",
    ] {
        grid_edits_and_deletes_only_the_keyed_row(conn.as_ref(), "mysql", table).await;
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
    let (_container, options) = start_mysql().await;
    let conn = connect(options).await;
    conn.execute("CREATE TABLE binary_exports (id INTEGER, payload LONGBLOB)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
    let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
    for (id, value) in values.iter().enumerate() {
        let statement = tablepro_core::sql_literal::build_insert_literal(
            "mysql",
            None,
            "binary_exports",
            &columns,
            &[Value::Int(id as i64), value.clone()],
        )
        .unwrap();
        conn.execute(&statement).await.unwrap();
    }
    let result = conn
        .query("SELECT payload FROM binary_exports ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        values.into_iter().map(|value| vec![value]).collect::<Vec<_>>()
    );
}

#[path = "support/mysql_identity_copy_contract.rs"]
mod mysql_identity_copy_contract;

#[tokio::test]
#[ignore = "requires docker"]
async fn decimal_results_preserve_all_fractional_digits() {
    let (_container, options) = start_mysql().await;
    let conn = connect(options).await;
    let result = conn
        .query("SELECT CAST('0.123456789012345678901234567891' AS DECIMAL(40,30))")
        .await
        .unwrap();
    let text = match &result.rows[0][0] {
        Value::Decimal(value) => value.to_string(),
        Value::Text(value) => value.clone(),
        other => panic!("unexpected value: {other:?}"),
    };
    assert_eq!(text, "0.123456789012345678901234567891");
}

#[path = "support/value_contracts.rs"]
mod value_contracts;

#[path = "support/invalid_calendar_mode.rs"]
mod invalid_calendar_mode;

#[path = "support/database_listing.rs"]
mod database_listing;

#[path = "support/char_padding_mode.rs"]
mod char_padding_mode;
#[path = "support/enum_sql_mode_contract.rs"]
mod enum_sql_mode_contract;
#[path = "support/timezone_contract.rs"]
mod timezone_contract;
#[path = "support/unsigned_subtraction.rs"]
mod unsigned_subtraction;
#[path = "support/wide_decimal_csv.rs"]
mod wide_decimal_csv;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_wide_decimal_csv_bound_and_literal_round_trips_preserve_all_digits() {
    let (_container, options) = start_mysql().await;
    let connection = connect(options).await;
    wide_decimal_csv::assert_csv_bound_and_literal_round_trips(connection.as_ref()).await;
}
