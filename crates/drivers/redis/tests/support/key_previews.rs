#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use drivers_redis::RedisDriver;
use tablepro_core::{DatabaseDriver, Value};

use crate::{opts, start_redis};

#[tokio::test]
#[ignore = "requires docker"]
async fn every_key_type_lists_with_its_type_and_a_preview() {
    let (_container, host, port) = start_redis().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();
    for command in [
        vec!["SET", "k_string", "hello"],
        vec!["HSET", "k_hash", "field", "value"],
        vec!["RPUSH", "k_list", "a", "b"],
        vec!["SADD", "k_set", "m"],
        vec!["ZADD", "k_zset", "1", "z"],
        vec!["XADD", "k_stream", "*", "f", "v"],
    ] {
        let mut cmd = redis::cmd(command[0]);
        for argument in &command[1..] {
            cmd.arg(*argument);
        }
        cmd.query_async::<redis::Value>(&mut native_connection).await.unwrap();
    }

    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let rows = connection.fetch_rows(None, "db0", 0, 50).await.unwrap().rows;
    let find = |key: &str| {
        rows.iter()
            .find(|row| row[0] == Value::Text(key.into()))
            .unwrap_or_else(|| panic!("{key} is listed"))
            .clone()
    };

    assert_eq!(find("k_string")[1], Value::Text("string".into()));
    assert_eq!(find("k_string")[3], Value::Text("hello".into()));
    assert_eq!(find("k_hash")[1], Value::Text("hash".into()));
    assert_eq!(find("k_hash")[3], Value::Text(r#"[("field", "value")]"#.into()));
    assert_eq!(find("k_list")[3], Value::Text(r#"["a", "b"]"#.into()));
    assert_eq!(find("k_set")[3], Value::Text(r#"["m"]"#.into()));
    assert_eq!(find("k_zset")[3], Value::Text(r#"["z"]"#.into()));
    assert_eq!(find("k_stream")[3], Value::Text("<stream>".into()));
    assert_eq!(find("k_string")[2], Value::Int(-1), "no expiry is reported as -1");
}
