#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ConnectOptions, DriverError};

use crate::{connect, start_pg};

async fn sqlstate_of(error: DriverError) -> Option<String> {
    match error {
        DriverError::Query { sqlstate, .. } => sqlstate,
        other => panic!("expected a query error, got {other:?}"),
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_read_only_connection_is_refused_writes_by_the_server() {
    let (_c, opts) = start_pg().await;
    let writer = connect(opts.clone()).await;
    writer
        .execute("CREATE TABLE jobs (id integer PRIMARY KEY)")
        .await
        .unwrap();
    writer.execute("CREATE SEQUENCE job_seq").await.unwrap();
    writer.execute("INSERT INTO jobs VALUES (1)").await.unwrap();

    let reader = connect(ConnectOptions {
        read_only: true,
        ..opts
    })
    .await;

    assert_eq!(reader.query("SELECT id FROM jobs").await.unwrap().rows.len(), 1);
    for sql in [
        "INSERT INTO jobs VALUES (2)",
        "CREATE TABLE copied AS SELECT * FROM jobs",
        "SELECT nextval('job_seq')",
        "WITH gone AS (DELETE FROM jobs RETURNING id) SELECT id FROM gone",
    ] {
        let error = reader.query(sql).await.unwrap_err();
        assert_eq!(sqlstate_of(error).await.as_deref(), Some("25006"), "{sql}");
    }
    assert_eq!(writer.query("SELECT id FROM jobs").await.unwrap().rows.len(), 1);
}
