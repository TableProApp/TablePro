#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_user_databases_and_hides_system_schemas() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE DATABASE alpha_db").await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert!(names.contains(&"alpha_db".to_string()), "{names:?}");
    for hidden in ["information_schema", "mysql", "performance_schema", "sys"] {
        assert!(!names.contains(&hidden.to_string()), "{hidden} leaked: {names:?}");
    }
}
