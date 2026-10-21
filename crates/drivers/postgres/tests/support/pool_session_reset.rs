#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn settings_and_temp_tables_do_not_survive_on_a_pooled_connection() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let backend = connection.query("SELECT pg_backend_pid()::text").await.unwrap().rows[0][0].clone();
    let default_path = connection.query("SHOW search_path").await.unwrap().rows[0][0].clone();

    connection.execute("SET search_path TO pg_catalog").await.unwrap();
    assert_eq!(
        connection.query("SELECT pg_backend_pid()::text").await.unwrap().rows[0][0],
        backend
    );
    connection.execute("CREATE TEMP TABLE leaked (id int)").await.unwrap();
    assert_eq!(
        connection.query("SELECT pg_backend_pid()::text").await.unwrap().rows[0][0],
        backend
    );

    for _ in 0..8 {
        let path = connection.query("SHOW search_path").await.unwrap().rows[0][0].clone();
        assert_eq!(
            connection.query("SELECT pg_backend_pid()::text").await.unwrap().rows[0][0],
            backend
        );
        assert_eq!(path, default_path);
        let temp = connection
            .query("SELECT to_regclass('pg_temp.leaked')::text")
            .await
            .unwrap()
            .rows[0][0]
            .clone();
        assert_eq!(temp, Value::Null);
    }
}
