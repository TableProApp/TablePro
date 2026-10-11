use super::*;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Value};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::redis::Redis;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::test]
#[ignore = "requires docker"]
async fn redis_guarded_refetch_preserves_binary_key_and_value() {
    let container = Redis::default().start().await.unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(6379).await.unwrap();
    let key = vec![0xff, b'?', b'\n'];
    let bytes: Vec<u8> = (0..9_000).map(|index| (index % 251) as u8).collect();
    let mut native = TcpStream::connect((host.as_str(), port)).await.unwrap();
    assert_eq!(redis_command(&mut native, &[b"SET", &key, &bytes]).await, b"OK");

    let connection: std::sync::Arc<dyn Connection> = std::sync::Arc::from(
        drivers_redis::RedisDriver
            .connect(ConnectOptions {
                host,
                port,
                database: "0".into(),
                ..Default::default()
            })
            .await
            .unwrap(),
    );
    let control = crate::services::operation_control::bounded(30);
    let columns = connection
        .fetch_columns_controlled(None, "db0", &control)
        .await
        .unwrap();
    let target = BrowseTarget {
        driver_id: "redis",
        schema: None,
        table: "db0",
        columns: &columns,
        filter: &tablepro_core::FilterSet::default(),
        hidden_columns: None,
    };
    let key_value = Value::Bytes(key.clone());
    let query = target.value_query(3, std::slice::from_ref(&key_value)).unwrap();
    let result = guarded_value_refetch(connection, "redis", &query, &control).await;
    assert_eq!(result.rows, vec![vec![Value::Bytes(bytes.clone())]]);
    assert_eq!(redis_command(&mut native, &[b"GET", &key]).await, bytes);
}

async fn redis_command(stream: &mut TcpStream, args: &[&[u8]]) -> Vec<u8> {
    let mut request = format!("*{}\r\n", args.len()).into_bytes();
    for arg in args {
        request.extend_from_slice(format!("${}\r\n", arg.len()).as_bytes());
        request.extend_from_slice(arg);
        request.extend_from_slice(b"\r\n");
    }
    stream.write_all(&request).await.unwrap();
    let mut prefix = [0];
    stream.read_exact(&mut prefix).await.unwrap();
    let mut line = Vec::new();
    loop {
        let mut byte = [0];
        stream.read_exact(&mut byte).await.unwrap();
        if byte[0] == b'\r' {
            stream.read_exact(&mut byte).await.unwrap();
            break;
        }
        line.push(byte[0]);
    }
    if prefix[0] == b'+' {
        return line;
    }
    assert_eq!(prefix[0], b'$');
    let length: usize = std::str::from_utf8(&line).unwrap().parse().unwrap();
    let mut value = vec![0; length];
    stream.read_exact(&mut value).await.unwrap();
    let mut terminator = [0; 2];
    stream.read_exact(&mut terminator).await.unwrap();
    assert_eq!(&terminator, b"\r\n");
    value
}
