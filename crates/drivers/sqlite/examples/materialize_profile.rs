use std::error::Error;
use std::io::Write;
use std::time::Instant;

use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver};

fn status_kb(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|line| line.starts_with(field))
                .and_then(|line| line.split_whitespace().nth(1)?.parse().ok())
        })
        .unwrap_or(0)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let rows: u64 = std::env::args()
        .nth(1)
        .ok_or("usage: materialize_profile ROWS")?
        .parse()?;
    let path = std::env::temp_dir().join(format!("bookie-profile-{rows}.sqlite"));
    let _ = std::fs::remove_file(&path);
    let options = ConnectOptions {
        database: path.display().to_string(),
        ..Default::default()
    };
    let connection = SqliteDriver.connect(options).await?;
    connection
        .execute(
            "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, flag INTEGER, created TEXT, note TEXT)",
        )
        .await?;
    connection
        .execute(&format!(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {rows}) \
             INSERT INTO people SELECT x, 'person-' || x, x * 1.5, x % 2, \
             datetime('2026-01-01', '+' || (x % 100000) || ' seconds'), \
             'a note of moderate length for row ' || x || ' to give text columns some weight' FROM c"
        ))
        .await?;

    let before = status_kb("VmRSS:");
    let started = Instant::now();
    let result = connection.query("SELECT * FROM people").await?;
    let elapsed = started.elapsed();
    let after = status_kb("VmRSS:");
    let peak = status_kb("VmHWM:");
    let mut out = std::io::stdout();
    writeln!(
        out,
        "rows_requested={rows} rows_returned={} truncated={} elapsed_ms={} rss_before_kb={before} rss_after_kb={after} delta_mb={:.1} peak_kb={peak}",
        result.rows.len(),
        result.truncated,
        elapsed.as_millis(),
        (after.saturating_sub(before)) as f64 / 1024.0,
    )?;
    let _ = std::fs::remove_file(&path);
    Ok(())
}
