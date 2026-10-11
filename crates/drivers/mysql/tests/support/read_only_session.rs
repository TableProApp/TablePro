#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ConnectOptions, DriverError};

use crate::{connect, start_mysql};

fn is_read_only_refusal(error: &DriverError) -> bool {
    matches!(error, DriverError::Query { sqlstate: Some(state), .. } if state == "25006")
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_read_only_connection_is_refused_writes_by_the_server() {
    let (_c, opts) = start_mysql().await;
    let writer = connect(opts.clone()).await;
    writer
        .execute("CREATE TABLE jobs (id INT PRIMARY KEY) ENGINE=InnoDB")
        .await
        .unwrap();
    writer.execute("INSERT INTO jobs VALUES (1)").await.unwrap();

    let reader = connect(ConnectOptions {
        read_only: true,
        ..opts
    })
    .await;

    assert_eq!(reader.query("SELECT id FROM jobs").await.unwrap().rows.len(), 1);
    for sql in [
        "INSERT INTO jobs VALUES (2)",
        "UPDATE jobs SET id = 3",
        "DELETE FROM jobs",
        "CREATE TABLE copied AS SELECT * FROM jobs",
    ] {
        let outcome = reader.execute(sql).await;
        let error = outcome.expect_err(sql);
        assert!(
            is_read_only_refusal(&error) || error.to_string().contains("read-only"),
            "{sql}: {error:?}"
        );
    }
    assert_eq!(writer.query("SELECT id FROM jobs").await.unwrap().rows.len(), 1);

    let mut session = reader.open_session().await.unwrap();
    let error = session
        .query_params_controlled(
            "INSERT INTO jobs VALUES (9)",
            &[],
            &tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(5)),
        )
        .await
        .expect_err("a session on a read-only connection must be read-only too");
    assert!(
        is_read_only_refusal(&error) || error.to_string().contains("read-only"),
        "{error:?}"
    );
}
