#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_clickhouse};

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_user_databases_and_hides_system_ones() {
    let (_c, opts) = start_clickhouse().await;
    let conn = connect(opts).await;
    conn.execute("CREATE DATABASE alpha_db").await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert!(names.contains(&"alpha_db".to_string()), "{names:?}");
    assert!(!names.contains(&"system".to_string()), "{names:?}");
}
