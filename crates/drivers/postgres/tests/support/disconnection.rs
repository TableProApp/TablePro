use super::*;

async fn postgres_proxy_dropping_update_ack(
    target_host: String,
    target_port: u16,
) -> (
    u16,
    std::sync::Arc<std::sync::atomic::AtomicBool>,
    tokio::task::JoinHandle<()>,
) {
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind lost-ack proxy");
    let port = listener.local_addr().expect("proxy address").port();
    let dropped_ack = std::sync::Arc::new(AtomicBool::new(false));
    let ack_state = dropped_ack.clone();
    let task = tokio::spawn(async move {
        loop {
            let (client, _) = listener.accept().await.expect("accept proxied connection");
            let host = target_host.clone();
            let dropped_ack = ack_state.clone();
            tokio::spawn(async move {
                let Ok(server) = TcpStream::connect((host.as_str(), target_port)).await else {
                    return;
                };
                let (mut client_read, mut client_write) = client.into_split();
                let (mut server_read, mut server_write) = server.into_split();
                let forward_client = tokio::spawn(async move {
                    let _ = tokio::io::copy(&mut client_read, &mut server_write).await;
                });
                let mut buffer = [0; 8192];
                let mut tail = Vec::new();
                while let Ok(read) = server_read.read(&mut buffer).await {
                    if read == 0 {
                        break;
                    }
                    let mut scan = std::mem::take(&mut tail);
                    scan.extend_from_slice(&buffer[..read]);
                    if scan.windows(b"UPDATE 1\0".len()).any(|window| window == b"UPDATE 1\0")
                        && !dropped_ack.swap(true, Ordering::SeqCst)
                    {
                        let _ = client_write.shutdown().await;
                        forward_client.abort();
                        return;
                    }
                    tail.extend_from_slice(&scan[scan.len().saturating_sub(b"UPDATE 1\0".len() - 1)..]);
                    if client_write.write_all(&buffer[..read]).await.is_err() {
                        break;
                    }
                }
                forward_client.abort();
            });
        }
    });
    (port, dropped_ack, task)
}

async fn tagged_query_is_active(connection: &dyn Connection, tag: &str) -> bool {
    let sql = format!(
        "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%{tag}%' AND pid <> pg_backend_pid()"
    );
    let result = connection.query(&sql).await.expect("inspect pg_stat_activity");
    matches!(result.rows.first().and_then(|row| row.first()), Some(Value::Int(count)) if *count > 0)
}

pub(super) async fn wait_for_tagged_query(connection: &dyn Connection, tag: &str, active: bool) {
    for _ in 0..100 {
        if tagged_query_is_active(connection, tag).await == active {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("query tag {tag} did not reach active={active}");
}

async fn tagged_query_pid(connection: &dyn Connection, tag: &str) -> Option<i64> {
    let sql = format!(
        "SELECT pid::bigint FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%{tag}%' AND pid <> pg_backend_pid()"
    );
    let result = connection.query(&sql).await.expect("inspect active query pid");
    result.rows.first().and_then(|row| match row.first() {
        Some(Value::Int(pid)) => Some(*pid),
        _ => None,
    })
}

async fn wait_for_tagged_query_pid(connection: &dyn Connection, tag: &str) -> Option<i64> {
    for _ in 0..100 {
        if let Some(pid) = tagged_query_pid(connection, tag).await {
            return Some(pid);
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    None
}

#[tokio::test]
#[ignore = "requires docker"]
async fn server_terminated_query_reports_disconnection_and_pool_recovers() {
    let (_container, opts) = start_pg().await;
    let connection: std::sync::Arc<dyn Connection> = PgDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let tag = "bookie_backend_termination";
    let running = connection.clone();
    let task = tokio::spawn(async move { running.query(&format!("SELECT pg_sleep(30) /* {tag} */")).await });

    let pid = wait_for_tagged_query_pid(observer.as_ref(), tag)
        .await
        .expect("tagged query must reach PostgreSQL");
    let terminated = observer
        .query(&format!("SELECT pg_terminate_backend({pid})"))
        .await
        .expect("terminate query backend");
    assert_eq!(terminated.rows, vec![vec![Value::Bool(true)]]);

    let error = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .expect("terminated query must not hang")
        .expect("query task")
        .expect_err("a terminated query must not return success");
    assert!(
        matches!(error, DriverError::Disconnected),
        "an I/O loss must be reported as disconnected, got {error:?}"
    );

    let recovered = connection
        .query("SELECT 1")
        .await
        .expect("pool must recover on a new connection");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect() {
    use std::sync::atomic::Ordering;

    let (_container, opts) = super::shared_container::start_pg_durable().await;
    let observer = connect(opts.clone()).await;
    assert_eq!(
        observer
            .query("SELECT current_setting('fsync'), current_setting('synchronous_commit'), current_setting('full_page_writes')")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("on".into()), Value::Text("on".into()), Value::Text("on".into())]],
    );
    observer
        .execute("CREATE TABLE lost_ack_target (id integer PRIMARY KEY, value integer NOT NULL)")
        .await
        .unwrap();
    observer
        .execute("CREATE TABLE lost_ack_audit (target_id integer NOT NULL)")
        .await
        .unwrap();
    observer
        .execute(
            "CREATE FUNCTION lost_ack_record_update() RETURNS trigger LANGUAGE plpgsql AS $$
             BEGIN INSERT INTO lost_ack_audit VALUES (NEW.id); RETURN NEW; END $$",
        )
        .await
        .unwrap();
    observer
        .execute(
            "CREATE TRIGGER lost_ack_record_update AFTER UPDATE ON lost_ack_target
             FOR EACH ROW EXECUTE FUNCTION lost_ack_record_update()",
        )
        .await
        .unwrap();
    observer
        .execute("INSERT INTO lost_ack_target VALUES (1, 0)")
        .await
        .unwrap();

    let (proxy_port, dropped_ack, proxy_task) = postgres_proxy_dropping_update_ack(opts.host.clone(), opts.port).await;
    let mut proxied_opts = opts;
    proxied_opts.host = "127.0.0.1".into();
    proxied_opts.port = proxy_port;
    let connection = PgDriver.connect(proxied_opts).await.expect("connect through proxy");
    let write = connection
        .execute("UPDATE lost_ack_target SET value = value + 1 WHERE id = 1")
        .await;
    assert!(
        dropped_ack.load(Ordering::SeqCst),
        "proxy must drop the committed UPDATE acknowledgement"
    );
    assert!(
        matches!(write, Err(DriverError::Disconnected)),
        "a write with a lost acknowledgement must remain uncertain, got {write:?}"
    );

    let recovered = connection
        .query("SELECT value FROM lost_ack_target WHERE id = 1")
        .await
        .expect("a later operation should reconnect the pool");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
    let audit = observer
        .query("SELECT target_id FROM lost_ack_audit ORDER BY target_id")
        .await
        .unwrap();
    assert_eq!(
        audit.rows,
        vec![vec![Value::Int(1)]],
        "the trigger audit is an independent replay oracle"
    );

    proxy_task.abort();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_disconnected_session_is_retired_without_affecting_the_shared_pool() {
    let (_container, opts) = start_pg().await;
    let connection = PgDriver.connect(opts.clone()).await.expect("connect");
    let observer = connect(opts).await;
    let mut session = connection.open_session().await.expect("open session");
    let tag = "bookie_session_backend_termination";
    let query = tokio::spawn(async move {
        let result = session
            .query_params_controlled(&format!("SELECT pg_sleep(30) /* {tag} */"), &[], &no_timeout())
            .await;
        (session, result)
    });

    let pid = wait_for_tagged_query_pid(observer.as_ref(), tag)
        .await
        .expect("tagged session query must reach PostgreSQL");
    let terminated = observer
        .query(&format!("SELECT pg_terminate_backend({pid})"))
        .await
        .expect("terminate session backend");
    assert_eq!(terminated.rows, vec![vec![Value::Bool(true)]]);

    let (mut session, result) = tokio::time::timeout(std::time::Duration::from_secs(5), query)
        .await
        .expect("terminated session query must not hang")
        .expect("session query task");
    let error = result.expect_err("a terminated session query must not succeed");
    assert!(matches!(error, DriverError::Disconnected), "{error:?}");
    assert!(!session.is_usable(), "a lost session must be retired");
    assert!(matches!(
        session.query_params_controlled("SELECT 1", &[], &no_timeout()).await,
        Err(DriverError::Internal(_))
    ));

    // The ordinary shared pool has its own recovery contract.
    assert_eq!(
        connection.query("SELECT 1").await.unwrap().rows,
        vec![vec![Value::Int(1)]]
    );
    session.close().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn backend_loss_during_row_stream_fails_the_whole_query_as_disconnected() {
    let (_container, opts) = start_pg().await;
    let connection: std::sync::Arc<dyn Connection> = PgDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let tag = "bookie_midstream_backend_termination";
    let running = connection.clone();
    let task = tokio::spawn(async move {
        running
            .query(&format!(
                "SELECT n, pg_sleep(0.05) FROM generate_series(1, 100) AS n /* {tag} */"
            ))
            .await
    });

    let pid = wait_for_tagged_query_pid(observer.as_ref(), tag)
        .await
        .expect("tagged streaming query must reach PostgreSQL");
    // Let the executor produce some rows before cutting its backend. The
    // public query API returns a complete result, so a partial result is a bug.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let terminated = observer
        .query(&format!("SELECT pg_terminate_backend({pid})"))
        .await
        .expect("terminate streaming query backend");
    assert_eq!(terminated.rows, vec![vec![Value::Bool(true)]]);

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
async fn a_restarted_postgres_server_restores_the_existing_pool() {
    let port_probe = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("reserve test port");
    let host_port = port_probe.local_addr().expect("test port address").port();
    drop(port_probe);
    let container = Postgres::default()
        .with_fsync_enabled()
        .with_tag("16-alpine")
        .with_mapped_port(host_port, 5432.tcp())
        .start()
        .await
        .expect("start PostgreSQL on a stable host port");
    let opts = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: host_port,
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new("postgres".to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    let connection: std::sync::Arc<dyn Connection> = PgDriver.connect(opts).await.expect("connect").into();
    let initial = connection.query("SELECT 1").await.expect("initial query");
    assert_eq!(initial.rows, vec![vec![Value::Int(1)]]);

    container.stop().await.expect("stop PostgreSQL server");
    let error = connection
        .query("SELECT 1")
        .await
        .expect_err("the stopped server must break the established operation");
    assert!(
        matches!(error, DriverError::Disconnected),
        "server loss on an established PostgreSQL pool connection must be Disconnected, got {error:?}"
    );

    container.start().await.expect("restart PostgreSQL server");
    let recovered = super::server_restart::retry_operation("PostgreSQL", || {
        let connection = connection.clone();
        async move { connection.query("SELECT 1").await }
    })
    .await
    .expect("the existing PostgreSQL pool reconnects after server restart");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn controlled_cancel_stops_server_query_and_keeps_pool_usable() {
    let (_container, opts) = start_pg().await;
    let connection: std::sync::Arc<dyn Connection> = PgDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move {
        operation_connection
            .query_controlled("SELECT pg_sleep(30) /* bookie_controlled_cancel */", &control)
            .await
    });

    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_cancel", true).await;
    token.cancel();
    let error = task.await.expect("query task").expect_err("query should be cancelled");
    assert!(matches!(error, DriverError::Cancelled));
    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_cancel", false).await;

    let result = connection.query("SELECT 1").await.expect("pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn controlled_parameterized_cancel_stops_server_query_and_keeps_pool_usable() {
    let (_container, opts) = start_pg().await;
    let connection: std::sync::Arc<dyn Connection> = PgDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = connect(opts).await;
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move {
        operation_connection
            .query_params_controlled(
                "SELECT $1::int FROM pg_sleep($2::double precision) /* bookie_controlled_params_cancel */",
                &[Value::Int(7), Value::Float(30.0)],
                &control,
            )
            .await
    });

    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_params_cancel", true).await;
    token.cancel();
    let error = task.await.expect("query task").expect_err("query should be cancelled");
    assert!(matches!(error, DriverError::Cancelled));
    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_params_cancel", false).await;

    let result = connection.query("SELECT 1").await.expect("pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);

    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let operation_connection = connection.clone();
    let task = tokio::spawn(async move {
        operation_connection
            .execute_params_controlled(
                "SELECT pg_sleep($1::double precision) /* bookie_controlled_execute_params_cancel */",
                &[Value::Float(30.0)],
                &control,
            )
            .await
    });

    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_execute_params_cancel", true).await;
    token.cancel();
    let error = task
        .await
        .expect("execute task")
        .expect_err("execute should be cancelled");
    assert!(matches!(error, DriverError::Cancelled));
    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_execute_params_cancel", false).await;

    let result = connection.query("SELECT 1").await.expect("pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn controlled_transaction_cancel_allows_rollback() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts.clone()).await;
    let observer = connect(opts).await;
    connection
        .execute("CREATE TABLE controlled_transaction (value int NOT NULL)")
        .await
        .expect("create table");
    let mut transaction = connection.begin().await.expect("begin transaction");
    transaction
        .execute_params_controlled(
            "INSERT INTO controlled_transaction (value) VALUES ($1)",
            &[Value::Int(9)],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("insert in transaction");
    let token = CancellationToken::new();
    let control = OperationControl::new(token.clone(), None);
    let task = tokio::spawn(async move {
        let result = transaction
            .query_params_controlled(
                "SELECT $1::int FROM pg_sleep($2::double precision) /* bookie_transaction_cancel */",
                &[Value::Int(7), Value::Float(30.0)],
                &control,
            )
            .await;
        (transaction, result)
    });

    wait_for_tagged_query(observer.as_ref(), "bookie_transaction_cancel", true).await;
    token.cancel();
    let (transaction, result) = task.await.expect("transaction task");
    let error = result.expect_err("transaction query should be cancelled");
    assert!(matches!(error, DriverError::Cancelled));
    wait_for_tagged_query(observer.as_ref(), "bookie_transaction_cancel", false).await;
    transaction.rollback().await.expect("rollback cancelled transaction");

    let result = connection
        .query("SELECT count(*) FROM controlled_transaction")
        .await
        .expect("count rows");
    assert_eq!(result.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn controlled_timeout_stops_server_query_and_keeps_pool_usable() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts.clone()).await;
    let observer = connect(opts).await;
    let control = OperationControl::new(
        CancellationToken::new(),
        Some(tokio::time::Instant::now() + std::time::Duration::from_millis(250)),
    );

    let error = connection
        .query_controlled("SELECT pg_sleep(30) /* bookie_controlled_timeout */", &control)
        .await
        .expect_err("query should time out");
    assert!(matches!(error, DriverError::TimedOut));
    wait_for_tagged_query(observer.as_ref(), "bookie_controlled_timeout", false).await;

    let result = connection.query("SELECT 1").await.expect("pool remains usable");
    assert_eq!(result.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn dropped_transaction_discards_uncommitted_session() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TABLE dropped_transaction (id integer PRIMARY KEY)")
        .await
        .expect("create table");
    let mut transaction = connection.begin().await.expect("begin transaction");
    transaction
        .execute("INSERT INTO dropped_transaction (id) VALUES (1)")
        .await
        .expect("insert row");
    drop(transaction);

    let result = connection
        .query("SELECT count(*) FROM dropped_transaction")
        .await
        .expect("query after dropped transaction");
    assert_eq!(result.rows, vec![vec![Value::Int(0)]]);
}
