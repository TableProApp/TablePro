use sqlx::migrate::Migrator;
use sqlx::sqlite::SqlitePoolOptions;

use super::schema;

#[tokio::test]
async fn a_run_kept_in_milliseconds_reads_in_microseconds_after_the_upgrade() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("pool");
    let before = schema::MIGRATOR.iter().count() - 1;
    Migrator::with_migrations(schema::MIGRATOR.iter().take(before).cloned().collect())
        .run(&pool)
        .await
        .expect("the migrations before microseconds");
    sqlx::query(
        "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, executed_at, \
         duration_ms, first_row_ms, server_ms, success) VALUES \
         ('a', 'SELECT 1', 'select 1', 'postgres', 'c', 'local', 1, 12, 3, NULL, 1), \
         ('b', 'SELECT 2', 'select 2', 'postgres', 'c', 'local', 2, NULL, NULL, NULL, 1)",
    )
    .execute(&pool)
    .await
    .expect("runs an older build kept");

    schema::MIGRATOR.run(&pool).await.expect("upgrade");

    let runs: Vec<(Option<i64>, Option<i64>, Option<i64>)> =
        sqlx::query_as("SELECT duration_us, first_row_us, server_us FROM history ORDER BY record_id")
            .fetch_all(&pool)
            .await
            .expect("runs");
    assert_eq!(runs, [(Some(12_000), Some(3_000), None), (None, None, None)]);
}
