#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{MongodbDriver, opts, start_mongo};
use tablepro_core::DatabaseDriver;

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_databases_with_data_and_hides_internal_ones() {
    let (_container, host, port) = start_mongo().await;
    let conn = MongodbDriver.connect(opts(&host, port, "alpha_db")).await.unwrap();
    conn.execute(r#"db.things.insertOne({"a": 1})"#).await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert!(names.contains(&"alpha_db".to_string()), "{names:?}");
    for hidden in ["admin", "local", "config"] {
        assert!(!names.contains(&hidden.to_string()), "{hidden} leaked: {names:?}");
    }
}
