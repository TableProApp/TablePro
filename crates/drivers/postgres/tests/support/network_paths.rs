#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::time::Duration;

use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};
use testcontainers::core::WaitFor;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

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
    outcomes.push(format!(
        "create: {:?}",
        connection
            .execute("CREATE TABLE pooled (id int PRIMARY KEY, note text)")
            .await
            .map(|_| ())
    ));
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
            break;
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
async fn pgbouncer_in_transaction_mode_without_prepared_statements_explains_itself() {
    let outcomes = pooled_outcomes("transaction", 0).await;
    assert!(!all_succeeded(&outcomes), "{outcomes:#?}");
    assert!(
        outcomes.iter().any(|line| line.contains("max_prepared_statements")),
        "the pooler symptom must come with a hint: {outcomes:#?}"
    );
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
