//! Run only against a disposable fixture. One process per scenario makes VmHWM comparable.
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};
use tablepro_core::{Connection, DriverError, MAX_QUERY_ROWS, OperationControl, Value};
use tablepro_release_tests::{Fixture, fixture_enabled};

fn peak_rss_kib() -> Option<u64> {
    std::fs::read_to_string("/proc/self/status")
        .ok()?
        .lines()
        .find(|line| line.starts_with("VmHWM:"))?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

async fn sample_server(
    connection: Arc<dyn Connection>,
    marker: String,
    running: Arc<AtomicBool>,
) -> Result<Option<f64>, DriverError> {
    let start = Instant::now();
    let mut first = None;
    let mut last = None;
    let control = OperationControl::with_timeout(Duration::from_secs(120));
    loop {
        let result = connection.query_params_controlled(
            "SELECT count(*) FROM pg_stat_activity WHERE state='active' AND query LIKE $1 AND pid <> pg_backend_pid()",
            &[Value::Text(format!("%{marker}%"))], &control).await?;
        let active = result.rows.first().and_then(|r| r.first()) == Some(&Value::Int(1));
        if active {
            first.get_or_insert(start.elapsed());
            last = Some(start.elapsed());
        } else if !running.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    Ok(first
        .zip(last)
        .map(|(first, last)| (last - first).as_secs_f64() * 1000.0))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if !fixture_enabled() {
        return Err("set TABLEPRO_FIXTURE_POSTGRES_RELEASE=1 for a disposable database".into());
    }
    let scenario = std::env::args().nth(1).unwrap_or_else(|| "first".into());
    if !["first", "filtered", "deep", "wide", "capped"].contains(&scenario.as_str()) {
        return Err("scenario must be first, filtered, deep, wide, or capped".into());
    }
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let observer: Arc<dyn Connection> = Arc::from(fixture.connect_verified().await);
    let name = format!("tablepro_bench_{}", uuid::Uuid::new_v4().simple());
    let control = OperationControl::with_timeout(Duration::from_secs(120));
    connection.execute_controlled(&format!("CREATE TABLE {name} AS SELECT n::bigint AS id, (n % 100)::integer AS bucket, repeat('x', 64) AS payload FROM generate_series(1, 1000000) n"), &control).await?;
    let result = async {
        connection
            .execute_controlled(&format!("ALTER TABLE {name} ADD PRIMARY KEY(id)"), &control)
            .await?;
        connection
            .execute_controlled(&format!("ANALYZE {name}"), &control)
            .await?;
        let sql = match scenario.as_str() {
            "filtered" => format!("SELECT * FROM {name} WHERE bucket = 42 ORDER BY id LIMIT 100"),
            "deep" => format!("SELECT * FROM {name} WHERE id > 900000 ORDER BY id LIMIT 100"),
            "wide" => {
                let columns = (0..200)
                    .map(|i| format!("payload AS c{i}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("SELECT {columns} FROM {name} ORDER BY id LIMIT 100")
            }
            "capped" => format!(
                "SELECT n AS id, repeat('x',64) AS payload FROM generate_series(1,{}) n",
                MAX_QUERY_ROWS + 100_000
            ),
            _ => format!("SELECT * FROM {name} ORDER BY id LIMIT 100"),
        };
        for attempt in 0..6 {
            let marker = format!("tablepro_sample_{}", uuid::Uuid::new_v4().simple());
            let running = Arc::new(AtomicBool::new(true));
            let task = tokio::spawn(sample_server(observer.clone(), marker.clone(), running.clone()));
            let start = Instant::now();
            let result = connection
                .query_controlled(
                    &format!("/* {marker} */ {sql}"),
                    &OperationControl::with_timeout(Duration::from_secs(120)),
                )
                .await;
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            running.store(false, Ordering::SeqCst);
            let observed = task.await.expect("observer task");
            let result = result?;
            let sampled_active_ms = observed?;
            if scenario == "capped" {
                assert!(!result.rows.is_empty());
                assert!(
                    result.rows.len() < MAX_QUERY_ROWS,
                    "decoded memory budget should bind first"
                );
            } else {
                assert_eq!(result.rows.len(), 100);
            }
            assert_eq!(result.truncated, scenario == "capped");
            println!(
                "{}",
                serde_json::json!({"scenario": scenario, "attempt": attempt, "warmup": attempt == 0,
                "elapsed_ms": elapsed_ms, "sampled_active_ms": sampled_active_ms,
                "peak_rss_kib": peak_rss_kib(), "rows": result.rows.len(), "truncated": result.truncated})
            );
        }
        Ok::<(), DriverError>(())
    }
    .await;
    let cleanup = connection
        .execute_controlled(
            &format!("DROP TABLE {name}"),
            &OperationControl::with_timeout(Duration::from_secs(30)),
        )
        .await;
    result?;
    cleanup?;
    Ok(())
}
