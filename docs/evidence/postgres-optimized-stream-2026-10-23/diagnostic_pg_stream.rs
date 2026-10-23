use std::time::{Duration, Instant};

use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, OperationControl, TlsConfig, Value};

const SQL: &str = "SELECT n AS row_id, 'person-' || n AS name, n * 1.5 AS amount, n % 2 AS active, timestamp '2026-01-01' + n * interval '1 second' AS created_at, 'a note of moderate length for row ' || n AS note FROM generate_series(1, 2000000) AS n";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port: u16 = std::env::args().nth(1).ok_or("missing fixture port")?.parse()?;
    let output = std::env::args().nth(2).ok_or("missing output path")?;
    let connection = PgDriver
        .connect(ConnectOptions {
            host: "127.0.0.1".into(),
            port,
            username: "postgres".into(),
            database: "postgres".into(),
            tls: TlsConfig::disabled(),
            read_only: true,
            ..Default::default()
        })
        .await?;
    let mut session = connection.open_session().await?;
    let control = OperationControl::with_timeout(Duration::from_secs(60));
    session
        .query_params_controlled("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], &control)
        .await?;
    let started = Instant::now();
    let cursor = session.open_query_cursor_controlled(SQL, &[], &control).await?;
    let mut rows = 0;
    let mut pages = 0;
    loop {
        let page = session.fetch_query_cursor_page_controlled(cursor, &control).await?;
        if page.result.truncated || page.result.columns.len() != 6 {
            return Err(DriverError::Unsupported("diagnostic page contract".into()).into());
        }
        for row in &page.result.rows {
            rows += 1;
            if row.first() != Some(&Value::Int(rows)) {
                return Err(DriverError::Unsupported("diagnostic row ordering".into()).into());
            }
        }
        pages += 1;
        if !page.has_next_page {
            break;
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    session.close_query_cursor_controlled(cursor, &control).await?;
    session.query_params_controlled("ROLLBACK", &[], &control).await?;
    session.close().await?;
    connection.close().await?;
    if rows != 2_000_000 {
        return Err(DriverError::Unsupported("diagnostic row count".into()).into());
    }
    serde_json::to_writer_pretty(std::fs::File::create(output)?, &serde_json::json!({
        "rows": rows, "pages": pages, "elapsed_seconds": elapsed,
        "scope": "raw PostgreSQL driver cursor; no PolicyGuard, GTK, audit or accessibility polling"
    }))?;
    Ok(())
}
