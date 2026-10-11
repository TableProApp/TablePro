#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[path = "../../shared/server_restart.rs"]
mod server_restart;

#[path = "../../shared/connect_refusal.rs"]
mod connect_refusal;
#[path = "support/disconnection.rs"]
mod disconnection;

#[tokio::test]
async fn an_unavailable_redis_server_is_classified_as_connection_refused() {
    connect_refusal::assert_connection_refused(&RedisDriver)
        .await
        .expect("Redis setup refusal remains distinct from established disconnect");
}

#[tokio::test]
async fn connection_loss_while_building_a_browse_page_fails_the_whole_page() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind RESP fixture");
    let port = listener.local_addr().unwrap().port();
    let type_requests = Arc::new(AtomicUsize::new(0));
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let type_requests = Arc::clone(&type_requests);
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut read = BufReader::new(read);
                loop {
                    let mut line = String::new();
                    if read.read_line(&mut line).await.expect("read request length") == 0 {
                        return;
                    }
                    let count: usize = line.trim().strip_prefix('*').unwrap().parse().unwrap();
                    let mut args = Vec::with_capacity(count);
                    for _ in 0..count {
                        line.clear();
                        read.read_line(&mut line).await.expect("read bulk length");
                        let len: usize = line.trim().strip_prefix('$').unwrap().parse().unwrap();
                        let mut bytes = vec![0; len];
                        read.read_exact(&mut bytes).await.expect("read bulk argument");
                        let mut crlf = [0; 2];
                        read.read_exact(&mut crlf).await.expect("read bulk terminator");
                        args.push(String::from_utf8(bytes).expect("Redis command is UTF-8"));
                    }

                    match args.first().map(String::as_str) {
                        Some("CLIENT") => write.write_all(b"+OK\r\n").await.expect("reply CLIENT metadata"),
                        Some("SELECT") => write.write_all(b"+OK\r\n").await.expect("reply SELECT"),
                        Some("SCAN") => write
                            .write_all(b"*2\r\n:0\r\n*1\r\n$11\r\nfixture:key\r\n")
                            .await
                            .expect("return one scanned key"),
                        Some("TYPE") if type_requests.fetch_add(1, Ordering::SeqCst) == 0 => {
                            return; // Lose the first established browse connection mid-page.
                        }
                        Some("TYPE") => write.write_all(b"+string\r\n").await.expect("reply TYPE"),
                        Some("TTL") => write.write_all(b":-1\r\n").await.expect("reply TTL"),
                        Some("GET") => write.write_all(b"$5\r\nvalue\r\n").await.expect("reply GET"),
                        command => panic!("unexpected Redis browse command: {command:?}"),
                    }
                    write.flush().await.expect("flush RESP reply");
                }
            });
        }
    });

    let connection = RedisDriver
        .connect(opts("127.0.0.1", port, "0"))
        .await
        .expect("connect to RESP disconnect fixture");
    let error = connection
        .fetch_rows(None, "db0", 0, 10)
        .await
        .expect_err("a key-read failure must reject the incomplete browse page");
    assert!(
        matches!(error, DriverError::Disconnected),
        "mid-page Redis connection loss must be Disconnected, got {error:?}"
    );

    let recovered = connection
        .fetch_rows(None, "db0", 0, 10)
        .await
        .expect("a later browse operation obtains a fresh connection");
    assert_eq!(
        recovered.rows,
        vec![vec![
            Value::Text("fixture:key".into()),
            Value::Text("string".into()),
            Value::Int(-1),
            Value::Text("value".into()),
        ]]
    );

    drop(connection);
    server.abort();
}

use drivers_redis::RedisDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, TlsConfig, Value};
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::{ContainerAsync, GenericImage};
use testcontainers_modules::redis::Redis;
use testcontainers_modules::testcontainers::runners::AsyncRunner;

struct BinaryBulk(Vec<u8>);
impl redis::ToRedisArgs for BinaryBulk {
    fn write_redis_args<W>(&self, out: &mut W)
    where
        W: ?Sized + redis::RedisWrite,
    {
        out.write_arg(&self.0);
    }
}

async fn start_redis() -> (ContainerAsync<Redis>, String, u16) {
    let container = Redis::default().start().await.expect("start redis container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(6379).await.expect("port");
    (container, host, port)
}

async fn start_redis_resp3() -> (ContainerAsync<GenericImage>, String, u16) {
    let container = GenericImage::new("redis", "7.4-alpine")
        .with_exposed_port(6379.tcp())
        .with_wait_for(WaitFor::message_on_stdout("Ready to accept connections"))
        .start()
        .await
        .expect("start Redis 7.4 fixture for RESP3");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(6379).await.expect("port");
    (container, host, port)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_lost_redis_server_is_reported_as_disconnected() {
    let (container, host, port) = start_redis().await;
    let options = opts(&host, port, "0");
    let connection = RedisDriver.connect(options.clone()).await.expect("connect");
    connection
        .query("PING")
        .await
        .expect("initial operation confirms server is reachable");

    container.stop().await.expect("stop Redis server");
    let error = connection
        .query("PING")
        .await
        .expect_err("an operation after server loss must fail");
    assert!(
        matches!(error, DriverError::Disconnected),
        "loss of an established Redis server must be reported as disconnected, got {error:?}"
    );

    container.start().await.expect("restart Redis server");
    let restarted_host = container.get_host().await.expect("restarted host").to_string();
    let restarted_port = container.get_host_port_ipv4(6379).await.expect("restarted Redis port");
    let recovered = server_restart::retry_operation("Redis", || {
        let options = opts(&restarted_host, restarted_port, "0");
        async move {
            let replacement = RedisDriver.connect(options).await?;
            replacement.query("PING").await
        }
    })
    .await
    .expect("Redis server restarts and accepts PING");
    assert_eq!(recovered.rows, vec![vec![Value::Text("PONG".into())]]);
}

#[tokio::test]
async fn value_contract_resp3_attribute_wire_frame_survives_the_request_response_connection() {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind RESP3 fixture");
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut read = BufReader::new(read);
                loop {
                    let mut line = String::new();
                    if read.read_line(&mut line).await.expect("read request length") == 0 {
                        return;
                    }
                    let count: usize = line.trim().strip_prefix('*').unwrap().parse().unwrap();
                    let mut args = Vec::with_capacity(count);
                    for _ in 0..count {
                        line.clear();
                        read.read_line(&mut line).await.expect("read bulk length");
                        let len: usize = line.trim().strip_prefix('$').unwrap().parse().unwrap();
                        let mut bytes = vec![0; len];
                        read.read_exact(&mut bytes).await.expect("read bulk argument");
                        let mut crlf = [0; 2];
                        read.read_exact(&mut crlf).await.expect("read bulk terminator");
                        args.push(String::from_utf8(bytes).expect("command is UTF-8"));
                    }

                    let response = match args.first().map(String::as_str) {
                        Some("HELLO") => concat!(
                            "%7\r\n+server\r\n+redis\r\n+version\r\n+7.4.0\r\n+proto\r\n:3\r\n",
                            "+id\r\n:1\r\n+mode\r\n+standalone\r\n+role\r\n+master\r\n+modules\r\n*0\r\n"
                        ),
                        Some("PING") => "|1\r\n+ttl\r\n:3600\r\n+PONG\r\n",
                        _ => "-ERR unexpected fixture command\r\n",
                    };
                    write.write_all(response.as_bytes()).await.expect("write RESP3 reply");
                    write.flush().await.expect("flush RESP3 reply");
                }
            });
        }
    });

    let connection = RedisDriver
        .connect(opts("127.0.0.1", port, "0"))
        .await
        .expect("connect to RESP3 protocol fixture");
    connection.query("HELLO 3").await.expect("enable RESP3");
    let result = connection.query("PING").await.expect("read attributed reply");
    assert_eq!(
        result.rows,
        vec![vec![Value::Json(serde_json::json!({
            "$redisAttribute": {
                "data": "PONG",
                "attributes": [["ttl", 3600]]
            }
        }))]],
        "RESP3 attribute framing must survive the actual socket decoder"
    );

    drop(connection);
    server.abort();
}

fn opts(host: &str, port: u16, database: &str) -> ConnectOptions {
    ConnectOptions {
        host: host.to_string(),
        port,
        database: database.to_string(),
        username: String::new(),
        password: secrecy::SecretString::new(String::new().into()),
        tls: TlsConfig::disabled(),
        ..Default::default()
    }
}

/// fetch_rows() browses a table named after a database other than the
/// connection's own -- it must restore the connection's own database
/// before returning, or the next call on this shared connection lands
/// wherever the browse last left it.
#[tokio::test]
#[ignore = "requires docker"]
async fn browsing_another_database_does_not_leak_into_later_queries() {
    let (_container, host, port) = start_redis().await;
    let conn = RedisDriver.connect(opts(&host, port, "0")).await.expect("connect");

    conn.query("SET home_key 1").await.expect("seed db0");

    let empty_page = tokio::time::timeout(std::time::Duration::from_secs(5), conn.fetch_rows(None, "db2", 0, 10))
        .await
        .expect("an empty SCAN must stop at its terminal cursor")
        .expect("browse db2");
    assert!(empty_page.rows.is_empty());

    let result = conn
        .query("GET home_key")
        .await
        .expect("read back on the connection's own db");
    assert_eq!(result.rows, vec![vec![Value::Text("1".into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_browsing_binary_string_values_preserves_the_native_bytes() {
    let (_container, host, port) = start_redis().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();
    let payload = vec![0xFF, 0x00, 0x41];
    redis::cmd("SET")
        .arg("browse_binary_value")
        .arg(BinaryBulk(payload.clone()))
        .query_async::<()>(&mut native_connection)
        .await
        .expect("seed binary string value");
    let native_bytes: Vec<u8> = redis::cmd("GET")
        .arg("browse_binary_value")
        .query_async(&mut native_connection)
        .await
        .expect("read native binary value");
    assert_eq!(native_bytes, payload);

    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let result = connection.fetch_rows(None, "db0", 0, 10).await.unwrap();

    assert_eq!(result.rows.len(), 1, "only the seeded key should be present");
    assert_eq!(
        result.rows[0],
        vec![
            Value::Text("browse_binary_value".into()),
            Value::Text("string".into()),
            Value::Int(-1),
            Value::Bytes(native_bytes),
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_browsing_binary_keys_preserves_the_native_bytes() {
    let (_container, host, port) = start_redis().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();
    let key = vec![0xFF, 0x00, 0x41];
    redis::cmd("SET")
        .arg(BinaryBulk(key.clone()))
        .arg("value")
        .query_async::<()>(&mut native_connection)
        .await
        .expect("seed binary key");
    let native_value: Vec<u8> = redis::cmd("GET")
        .arg(BinaryBulk(key.clone()))
        .query_async(&mut native_connection)
        .await
        .expect("read native value at binary key");
    assert_eq!(native_value, b"value");

    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let result = connection.fetch_rows(None, "db0", 0, 10).await.unwrap();

    assert_eq!(result.rows.len(), 1, "only the seeded key should be present");
    assert_eq!(
        result.rows[0],
        vec![
            Value::Bytes(key),
            Value::Text("string".into()),
            Value::Int(-1),
            Value::Text("value".into()),
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_redis_scan_keeps_fetching_until_the_requested_page_is_full() {
    use std::collections::HashSet;

    const KEY_COUNT: usize = 2048;
    let (_container, host, port) = start_redis().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();

    let mut seed = redis::cmd("MSET");
    for index in 0..KEY_COUNT {
        seed.arg(format!("scan_page_{index:04}")).arg("value");
    }
    seed.query_async::<()>(&mut native_connection)
        .await
        .expect("seed keys across multiple SCAN batches");

    let (mut cursor, first_batch): (u64, Vec<String>) = redis::cmd("SCAN")
        .arg(0)
        .arg("MATCH")
        .arg("scan_page_*")
        .arg("COUNT")
        .arg(100)
        .query_async(&mut native_connection)
        .await
        .expect("inspect the native first SCAN batch");
    assert_ne!(cursor, 0, "the fixture must require more than one SCAN batch");
    let first_batch_len = first_batch.len();
    assert!(first_batch_len < KEY_COUNT);

    let mut native_keys: HashSet<String> = first_batch.into_iter().collect();
    while cursor != 0 {
        let (next, batch): (u64, Vec<String>) = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg("scan_page_*")
            .arg("COUNT")
            .arg(100)
            .query_async(&mut native_connection)
            .await
            .expect("read the next native SCAN batch");
        native_keys.extend(batch);
        cursor = next;
    }
    assert_eq!(native_keys.len(), KEY_COUNT, "native SCAN must census the fixture");

    let requested = first_batch_len + 1;
    assert!(requested <= KEY_COUNT);
    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        connection.fetch_rows(None, "db0", 0, requested as u64),
    )
    .await
    .expect("browse must stop after collecting the requested page")
    .unwrap();

    assert_eq!(result.rows.len(), requested);
    let observed: HashSet<String> = result
        .rows
        .iter()
        .map(|row| match row.first() {
            Some(Value::Text(key)) => key.clone(),
            other => panic!("Redis browse key must be text, got {other:?}"),
        })
        .collect();
    assert_eq!(observed.len(), result.rows.len(), "a page must not repeat keys");
    assert!(
        observed.is_subset(&native_keys),
        "every browsed key must exist natively"
    );
    assert!(result.rows.iter().all(|row| row[3] == Value::Text("value".into())));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_preserves_integer_and_text_command_arguments() {
    let (_container, host, port) = start_redis().await;
    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let corpus: serde_json::Value =
        serde_json::from_str(include_str!("../../../../testdata/value-contract.json")).unwrap();
    for integer in corpus["integers"].as_array().unwrap() {
        let integer = integer.as_str().unwrap();
        connection.query(&format!("SET boundary {integer}")).await.unwrap();
        assert_eq!(
            connection.query("INCRBY boundary 0").await.unwrap().rows,
            vec![vec![Value::Int(integer.parse().unwrap())]]
        );
    }
    for text in corpus["texts"].as_array().unwrap() {
        let text = text.as_str().unwrap();
        let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
        connection.query(&format!("SET boundary \"{escaped}\"")).await.unwrap();
        assert_eq!(
            connection.query("GET boundary").await.unwrap().rows,
            vec![vec![Value::Text(text.into())]]
        );
    }
    assert_eq!(
        connection.query("GET missing_value").await.unwrap().rows,
        vec![vec![Value::Null]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_resp3_hash_map_preserves_binary_fields_and_values() {
    let (_container, host, port) = start_redis_resp3().await;
    let native = redis::Client::open(format!("redis://{host}:{port}/0")).unwrap();
    let mut native_connection = native.get_multiplexed_async_connection().await.unwrap();
    redis::cmd("HSET")
        .arg("value_contract_hash")
        .arg("name")
        .arg("Ada")
        .arg("opaque")
        .arg(BinaryBulk(vec![0xFF, 0x00, 0x41]))
        .query_async::<i64>(&mut native_connection)
        .await
        .expect("seed text and binary hash values");
    redis::cmd("XADD")
        .arg("value_contract_stream")
        .arg("*")
        .arg("sensor")
        .arg("temperature")
        .arg("opaque")
        .arg(BinaryBulk(vec![0xFF, 0x00, 0x41]))
        .query_async::<String>(&mut native_connection)
        .await
        .expect("seed nested stream entry");

    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    let hello = connection
        .query("HELLO 3")
        .await
        .expect("switch this connection to RESP3");
    assert!(
        hello
            .rows
            .iter()
            .any(|row| row == &[Value::Text("proto".into()), Value::Int(3)]),
        "HELLO must return a structured RESP3 map: {:?}",
        hello.rows
    );

    let result = connection
        .query("HGETALL value_contract_hash")
        .await
        .expect("read RESP3 hash map");
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        ["key", "value"]
    );
    assert!(
        result
            .rows
            .iter()
            .any(|row| { row == &[Value::Text("name".into()), Value::Text("Ada".into())] })
    );
    assert!(
        result
            .rows
            .iter()
            .any(|row| { row == &[Value::Text("opaque".into()), Value::Bytes(vec![0xFF, 0x00, 0x41])] }),
        "RESP3 binary hash value changed: {:?}",
        result.rows
    );

    let stream = connection
        .query("XREAD STREAMS value_contract_stream 0")
        .await
        .expect("read RESP3 nested stream map");
    assert_eq!(stream.rows.len(), 1, "one stream should produce one outer row");
    assert_eq!(stream.rows[0][0], Value::Text("value_contract_stream".into()));
    let Value::Json(nested) = &stream.rows[0][1] else {
        panic!("nested stream entries must not be flattened: {:?}", stream.rows[0][1]);
    };
    assert!(nested.to_string().contains("sensor"), "{nested}");
    assert!(nested.to_string().contains(r#""$redisBytes":"ff0041""#), "{nested}");
    assert!(!nested.to_string().contains("BulkString"), "{nested}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_redis_stream_commands_are_refused_without_consuming_the_connection() {
    let (_container, host, port) = start_redis_resp3().await;
    let connection = RedisDriver.connect(opts(&host, port, "0")).await.unwrap();
    connection.query("HELLO 3").await.expect("enable RESP3");

    for command in [
        "SUBSCRIBE updates",
        "PSUBSCRIBE updates.*",
        "SSUBSCRIBE updates",
        "UNSUBSCRIBE updates",
        "PUNSUBSCRIBE updates.*",
        "SUNSUBSCRIBE updates",
        "MONITOR",
        "CLIENT TRACKING ON BCAST",
        "CLIENT TRACKING ON OPTIN NOLOOP",
        "CLIENT TRACKING ON REDIRECT 1",
        "cLiEnT tRaCkInG oN bCaSt nOlOoP",
    ] {
        let error = connection
            .query(command)
            .await
            .expect_err("streaming commands must not return a misleading one-shot result");
        assert!(
            matches!(error, tablepro_core::DriverError::Unsupported(_)),
            "{command} should have a visible unsupported result, got {error:?}"
        );
        assert!(
            error.to_string().to_ascii_lowercase().contains("stream"),
            "the refusal should explain the unsupported streaming operation: {error}"
        );
    }

    assert_eq!(
        connection.query("CLIENT TRACKING OFF").await.unwrap().rows,
        vec![vec![Value::Text("OK".into())]],
        "disabling tracking is a one-shot command and remains available"
    );
    assert_eq!(
        connection.query("PUBLISH updates payload").await.unwrap().rows,
        vec![vec![Value::Int(0)]],
        "ordinary one-shot PUBLISH must remain available"
    );
    assert!(
        connection.query("PUBSUB CHANNELS").await.is_ok(),
        "one-shot Pub/Sub inspection remains available"
    );
    assert!(
        !connection.query("CLIENT LIST").await.unwrap().rows.is_empty(),
        "ordinary client inspection remains available"
    );

    assert_eq!(
        connection.query("PING").await.unwrap().rows,
        vec![vec![Value::Text("PONG".into())]],
        "refused stream commands must not leave the connection in Pub/Sub mode"
    );
}
