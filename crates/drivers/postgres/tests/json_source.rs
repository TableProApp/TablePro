#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use drivers_postgres::PgDriver;
use tablepro_core::{DatabaseDriver, Value};

#[path = "support/shared_container.rs"]
#[allow(dead_code)]
mod shared_container;

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_json_keeps_duplicate_keys_order_precision_and_source_text() {
    let (_fixture, options) = shared_container::start_pg().await;
    let connection = PgDriver.connect(options).await.unwrap();
    let source = "{ \"z\": 1, \"z\": 2, \"n\": 1.0000000000000000000000000000000000000001 }";
    let result = connection
        .query(&format!("SELECT '{source}'::json AS value"))
        .await
        .unwrap();

    assert_eq!(result.rows, vec![vec![Value::JsonText(source.into())]]);
    let bound = connection
        .query_params("SELECT $1::json::text AS value", &[Value::JsonText(source.into())])
        .await
        .unwrap();

    assert_eq!(bound.rows, vec![vec![Value::Text(source.into())]]);
}
