use std::error::Error;

use drivers_postgres::PgDriver;
use secrecy::SecretString;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};
use tablepro_test_fixtures::{HbaMode, PostgresFixture};

type TestResult = Result<(), Box<dyn Error>>;

const BACKEND_USES_TLS: &str = "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()";

fn connect_options(fixture: &PostgresFixture) -> ConnectOptions {
    let credentials = fixture.password_credentials();
    ConnectOptions {
        host: fixture.host().to_owned(),
        port: fixture.port(),
        database: fixture.database().to_owned(),
        username: credentials.username,
        password: SecretString::from(credentials.password),
        use_tls: true,
        ..Default::default()
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn prefer_negotiates_tls() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::HostSslOnly).await?;
    let credentials = fixture.password_credentials();
    let options = PgConnectOptions::new()
        .host(fixture.host())
        .port(fixture.port())
        .database(fixture.database())
        .username(&credentials.username)
        .password(&credentials.password)
        .ssl_mode(PgSslMode::Prefer);

    let pool = PgPoolOptions::new().max_connections(1).connect_with(options).await?;
    let uses_tls: bool = sqlx::query_scalar(BACKEND_USES_TLS).fetch_one(&pool).await?;

    assert!(uses_tls, "sslmode=prefer left the connection in plaintext");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn require_succeeds() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::HostSslOnly).await?;

    let connection = PgDriver.connect(connect_options(&fixture)).await?;
    let result = connection.query(BACKEND_USES_TLS).await?;

    assert_eq!(result.rows.len(), 1);
    assert_eq!(result.rows[0][0], Value::Bool(true));
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn plaintext_is_refused_by_a_tls_only_server() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::HostSslOnly).await?;
    let options = ConnectOptions {
        use_tls: false,
        ..connect_options(&fixture)
    };

    let refused = PgDriver.connect(options).await;

    assert!(refused.is_err());
    Ok(())
}
