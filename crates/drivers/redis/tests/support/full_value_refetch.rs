#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use drivers_redis::RedisDriver;
use tablepro_core::{DatabaseDriver, DriverError, Value};

use crate::{opts, start_redis};

const FULL_VALUE: &str = "SELECT \"Value\" FROM \"db{db}\" WHERE \"Key\" = ?";

fn value_query(database: u8) -> String {
    FULL_VALUE.replace("{db}", &database.to_string())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_full_value_of_a_string_key_is_refetched_beyond_the_grid_preview() {
    let (_container, host, port) = start_redis().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();
    let long = "x".repeat(20_000);
    let binary = vec![0xFF_u8, 0x00, 0x41];
    redis::cmd("SET")
        .arg("long")
        .arg(&long)
        .query_async::<()>(&mut native_connection)
        .await
        .unwrap();
    redis::cmd("SET")
        .arg("bin")
        .arg(&binary)
        .query_async::<()>(&mut native_connection)
        .await
        .unwrap();
    redis::cmd("RPUSH")
        .arg("list")
        .arg("a")
        .query_async::<()>(&mut native_connection)
        .await
        .unwrap();
    redis::cmd("SELECT")
        .arg(1)
        .query_async::<()>(&mut native_connection)
        .await
        .unwrap();
    redis::cmd("SET")
        .arg("other")
        .arg("elsewhere")
        .query_async::<()>(&mut native_connection)
        .await
        .unwrap();

    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let query = value_query(0);

    let found = connection
        .query_params(&query, &[Value::Text("long".into())])
        .await
        .unwrap();
    assert_eq!(
        found.rows,
        vec![vec![Value::Text(long)]],
        "the whole value, not a preview"
    );

    let found = connection
        .query_params(&query, &[Value::Text("bin".into())])
        .await
        .unwrap();
    assert_eq!(found.rows, vec![vec![Value::Bytes(binary)]], "binary bytes are kept");

    let found = connection
        .query_params(&query, &[Value::Bytes(b"long".to_vec())])
        .await
        .unwrap();
    assert_eq!(found.rows.len(), 1, "a binary key parameter finds the same key");

    let missing = connection
        .query_params(&query, &[Value::Text("absent".into())])
        .await
        .unwrap();
    assert!(
        missing.rows.is_empty(),
        "a missing key is an empty result, not an error"
    );

    let wrong_type = connection.query_params(&query, &[Value::Text("list".into())]).await;
    assert!(matches!(wrong_type, Err(DriverError::Unsupported(_))), "{wrong_type:?}");

    let other = connection
        .query_params(&value_query(1), &[Value::Text("other".into())])
        .await
        .unwrap();
    assert_eq!(
        other.rows,
        vec![vec![Value::Text("elsewhere".into())]],
        "the query names its own database"
    );
}
