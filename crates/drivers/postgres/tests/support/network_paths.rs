#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, OperationControl, Value};
use testcontainers::core::WaitFor;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use tokio_util::sync::CancellationToken;

use crate::start_pg;

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

async fn start_pgbouncer(
    upstream: &ConnectOptions,
    pool_mode: &str,
    prepared: u32,
) -> (ContainerAsync<GenericImage>, ConnectOptions) {
    let port = free_port();
    let container = GenericImage::new("edoburu/pgbouncer", "v1.24.1-p1")
        .with_wait_for(WaitFor::Nothing)
        .with_network("host")
        .with_env_var("DB_HOST", "127.0.0.1")
        .with_env_var("DB_PORT", upstream.port.to_string())
        .with_env_var("DB_USER", "postgres")
        .with_env_var("DB_PASSWORD", "postgres")
        .with_env_var("DB_NAME", "*")
        .with_env_var("AUTH_TYPE", "scram-sha-256")
        .with_env_var("POOL_MODE", pool_mode)
        .with_env_var("LISTEN_PORT", port.to_string())
        .with_env_var("MAX_PREPARED_STATEMENTS", prepared.to_string())
        .with_env_var("ADMIN_USERS", "postgres")
        // Session mode pins one server connection per client connection; the driver pool may open 4.
        .with_env_var("DEFAULT_POOL_SIZE", "5")
        .start()
        .await
        .expect("start pgbouncer");
    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        ..upstream.clone()
    };
    (container, options)
}

async fn connect_when_ready(options: &ConnectOptions) -> Box<dyn Connection> {
    for _ in 0..40 {
        if let Ok(connection) = drivers_postgres::PgDriver.connect(options.clone()).await
            && connection.query("SELECT 1").await.is_ok()
        {
            return connection;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("pgbouncer never accepted a connection");
}

async fn exercise(connection: &dyn Connection) -> Vec<String> {
    let mut outcomes = Vec::new();
    let created = connection
        .execute("CREATE TABLE pooled (id int PRIMARY KEY, note text)")
        .await
        .map(|_| ());
    outcomes.push(format!("create: {created:?}"));
    if created.is_err() {
        return outcomes;
    }
    for id in 0..20 {
        let inserted = connection
            .execute_params(
                "INSERT INTO pooled VALUES ($1, $2)",
                &[Value::Int(id), Value::Text(format!("row {id}"))],
            )
            .await
            .map(|result| result.rows_affected);
        if !matches!(inserted, Ok(1)) {
            outcomes.push(format!("insert {id}: {inserted:?}"));
            return outcomes;
        }
    }
    outcomes.push(format!(
        "count: {:?}",
        connection
            .query("SELECT count(*) FROM pooled")
            .await
            .map(|result| result.rows[0][0].clone())
    ));
    outcomes.push(format!(
        "transaction: {:?}",
        connection
            .execute_in_transaction(&[
                (
                    "UPDATE pooled SET note = $1 WHERE id = $2".to_owned(),
                    vec![Value::Text("changed".into()), Value::Int(1)]
                ),
                ("DELETE FROM pooled WHERE id = $1".to_owned(), vec![Value::Int(2)]),
            ])
            .await
    ));
    outcomes
}

async fn pooled_outcomes(mode: &str, prepared: u32) -> Vec<String> {
    let (_server, upstream) = start_pg().await;
    let (_bouncer, options) = start_pgbouncer(&upstream, mode, prepared).await;
    let connection = connect_when_ready(&options).await;
    exercise(connection.as_ref()).await
}

fn all_succeeded(outcomes: &[String]) -> bool {
    outcomes[0] == "create: Ok(())" && outcomes[1] == "count: Ok(Int(20))" && outcomes[2] == "transaction: Ok([1, 1])"
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pgbouncer_in_transaction_mode_works_when_it_supports_prepared_statements() {
    let outcomes = pooled_outcomes("transaction", 200).await;
    assert!(all_succeeded(&outcomes), "{outcomes:#?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pgbouncer_in_session_mode_works() {
    let outcomes = pooled_outcomes("session", 0).await;
    assert!(all_succeeded(&outcomes), "{outcomes:#?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pgbouncer_without_prepared_statement_tracking_succeeds_or_explains_a_conflict() {
    let outcomes = pooled_outcomes("transaction", 0).await;
    assert!(
        all_succeeded(&outcomes) || outcomes.iter().any(|line| line.contains("max_prepared_statements")),
        "the pooler symptom must come with a hint: {outcomes:#?}"
    );
    assert!(
        outcomes.iter().all(|line| {
            if line.contains("Err(") {
                return line.contains("max_prepared_statements");
            }
            matches!(
                line.as_str(),
                "create: Ok(())" | "count: Ok(Int(20))" | "transaction: Ok([1, 1])"
            )
        }),
        "unexpected pooler outcome: {outcomes:#?}"
    );
}

async fn query_is_active(observer: &dyn Connection, marker: &str) -> bool {
    let result = observer
        .query(&format!(
            "SELECT count(*)::bigint FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%{marker}%'"
        ))
        .await
        .unwrap();
    matches!(result.rows.first().and_then(|row| row.first()), Some(Value::Int(count)) if *count > 0)
}

async fn wait_for_query_state(observer: &dyn Connection, marker: &str, active: bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if query_is_active(observer, marker).await == active {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap();
}

async fn check_pool_cancellation(pool_mode: &'static str, target_sql: &'static str, marker: &'static str, write: bool) {
    let (_server, upstream) = start_pg().await;
    let (_bouncer, options) = start_pgbouncer(&upstream, pool_mode, 200).await;
    let observer = drivers_postgres::PgDriver.connect(upstream).await.unwrap();
    if write {
        observer
            .execute("CREATE TABLE pgbouncer_cancelled_write (id int PRIMARY KEY)")
            .await
            .unwrap();
    }
    let target_connection = drivers_postgres::PgDriver.connect(options.clone()).await.unwrap();
    let mut target = target_connection.open_session().await.unwrap();
    let blocker: Arc<dyn Connection> = drivers_postgres::PgDriver.connect(options).await.unwrap().into();
    let blocker_token = CancellationToken::new();
    let blocker_control = OperationControl::new(blocker_token.clone(), None);
    let blocker_task = tokio::spawn(async move {
        blocker
            .query_controlled("SELECT pg_sleep(30) /* bookie_pgbouncer_blocker */", &blocker_control)
            .await
    });
    wait_for_query_state(observer.as_ref(), "bookie_pgbouncer_blocker", true).await;

    let target_token = CancellationToken::new();
    let target_control = OperationControl::new(target_token.clone(), None);
    let target_task = tokio::spawn(async move {
        let result = target.query_params_controlled(target_sql, &[], &target_control).await;
        (target, result)
    });
    wait_for_query_state(observer.as_ref(), marker, true).await;
    target_token.cancel();
    let (mut target, target_result) = tokio::time::timeout(Duration::from_secs(10), target_task)
        .await
        .unwrap()
        .unwrap();
    let blocker_kept_running = query_is_active(observer.as_ref(), "bookie_pgbouncer_blocker").await;
    blocker_token.cancel();
    let blocker_result = tokio::time::timeout(Duration::from_secs(10), blocker_task)
        .await
        .unwrap()
        .unwrap();

    assert!(
        blocker_kept_running,
        "cancelling one client stopped the other client's query"
    );
    assert!(
        matches!(target_result, Err(tablepro_core::DriverError::Cancelled)),
        "{target_result:?}"
    );
    assert!(
        matches!(blocker_result, Err(tablepro_core::DriverError::Cancelled)),
        "{blocker_result:?}"
    );
    assert!(target.is_usable());
    let clean_query = target
        .query_params_controlled("SELECT 1", &[], &crate::no_timeout())
        .await
        .unwrap();
    assert_eq!(clean_query.rows, vec![vec![Value::Int(1)]]);
    if write {
        let stored = observer
            .query("SELECT count(*)::bigint FROM pgbouncer_cancelled_write")
            .await
            .unwrap();
        assert_eq!(stored.rows, vec![vec![Value::Int(0)]]);
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn transaction_pool_cancellation_does_not_stop_another_clients_query() {
    check_pool_cancellation(
        "transaction",
        "SELECT pg_sleep(30) /* bookie_pgbouncer_target */",
        "bookie_pgbouncer_target",
        false,
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn transaction_pool_cancellation_does_not_stop_another_clients_write() {
    check_pool_cancellation(
        "transaction",
        "WITH pause AS MATERIALIZED (SELECT pg_sleep(30)) INSERT INTO pgbouncer_cancelled_write SELECT 1 FROM pause RETURNING id /* bookie_pgbouncer_write */",
        "bookie_pgbouncer_write",
        true,
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn session_pool_cancellation_stops_its_query_without_stopping_another_client() {
    check_pool_cancellation(
        "session",
        "SELECT pg_sleep(30) /* bookie_pgbouncer_target */",
        "bookie_pgbouncer_target",
        false,
    )
    .await;
}

async fn forward_ipv6_loopback_to(upstream_port: u16) -> Option<u16> {
    let listener = tokio::net::TcpListener::bind("[::1]:0").await.ok()?;
    let port = listener.local_addr().ok()?.port();
    tokio::spawn(async move {
        while let Ok((mut inbound, _)) = listener.accept().await {
            tokio::spawn(async move {
                if let Ok(mut outbound) = tokio::net::TcpStream::connect(("127.0.0.1", upstream_port)).await {
                    let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
                }
            });
        }
    });
    Some(port)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_ipv6_loopback_host_connects_bare_or_in_brackets() {
    let (_server, upstream) = start_pg().await;
    let Some(port) = forward_ipv6_loopback_to(upstream.port).await else {
        eprintln!("skipped: this host has no IPv6 loopback");
        return;
    };
    for host in ["::1", "[::1]"] {
        let connection = drivers_postgres::PgDriver
            .connect(ConnectOptions {
                host: host.into(),
                port,
                ..upstream.clone()
            })
            .await
            .unwrap_or_else(|error| panic!("{host}: {error:?}"));
        assert_eq!(connection.query("SELECT 1").await.unwrap().rows.len(), 1, "{host}");
    }
}
