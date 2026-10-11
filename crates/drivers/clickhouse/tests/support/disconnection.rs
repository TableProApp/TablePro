use super::*;
use std::io;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

async fn start_clickhouse_row_stream(
    tag: &'static str,
) -> (
    ContainerAsync<GenericImage>,
    ConnectOptions,
    std::sync::Arc<dyn tablepro_core::Connection>,
    tokio::task::JoinHandle<Result<tablepro_core::QueryResult, DriverError>>,
) {
    let (container, opts) = super::start_clickhouse().await;
    let connection: std::sync::Arc<dyn tablepro_core::Connection> =
        ClickhouseDriver.connect(opts.clone()).await.expect("connect").into();
    let observer = super::connect(opts.clone()).await;
    let running = connection.clone();
    let task = tokio::spawn(async move {
        running
            .query(&format!(
                "SELECT sleepEachRow(0.05) FROM numbers(1000) \
                 SETTINGS max_block_size = 1 /* {tag} */"
            ))
            .await
    });

    let mut running_query = false;
    for _ in 0..200 {
        let result = observer
            .query(&format!(
                "SELECT query_id FROM system.processes \
                 WHERE query LIKE '%{tag}%' AND query NOT LIKE '%system.processes%'"
            ))
            .await
            .expect("inspect active ClickHouse query");
        if !result.rows.is_empty() {
            running_query = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(running_query, "tagged row-stream query must reach system.processes");
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    (container, opts, connection, task)
}

async fn restart_clickhouse_and_query(container: &ContainerAsync<GenericImage>, opts: ConnectOptions) {
    container.start().await.expect("restart ClickHouse");
    let mut replacement_options = opts;
    replacement_options.host = container.get_host().await.expect("restarted host").to_string();
    replacement_options.port = container
        .get_host_port_ipv4(8123)
        .await
        .expect("restarted ClickHouse port");
    let recovered = super::server_restart::retry_operation("ClickHouse", || {
        let options = replacement_options.clone();
        async move {
            let replacement = ClickhouseDriver.connect(options).await?;
            replacement.query("SELECT 1").await
        }
    })
    .await
    .expect("ClickHouse restart accepts a fresh query");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn server_loss_during_row_stream_fails_the_whole_query_as_disconnected() {
    let (container, opts, connection, task) =
        start_clickhouse_row_stream("bookie_clickhouse_hard_stop_midstream").await;
    container
        .stop_with_timeout(Some(0))
        .await
        .expect("forcibly stop ClickHouse during row stream");

    let error = tokio::time::timeout(std::time::Duration::from_secs(10), task)
        .await
        .expect("interrupted ClickHouse row stream must not hang")
        .expect("query task")
        .expect_err("interrupted row stream must not return a partial result");
    assert!(
        matches!(error, DriverError::Disconnected),
        "mid-stream ClickHouse server loss must be disconnected, got {error:?}"
    );

    assert!(matches!(
        connection.query("SELECT 1").await,
        Err(DriverError::Disconnected)
    ));
    restart_clickhouse_and_query(&container, opts).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn graceful_server_stop_during_row_stream_returns_an_error_not_partial_rows() {
    let (container, _opts, _connection, task) =
        start_clickhouse_row_stream("bookie_clickhouse_graceful_stop_midstream").await;
    container
        .stop()
        .await
        .expect("gracefully stop ClickHouse during row stream");

    let error = tokio::time::timeout(std::time::Duration::from_secs(10), task)
        .await
        .expect("interrupted ClickHouse row stream must not hang")
        .expect("query task")
        .expect_err("a terminal ClickHouse exception row must not be returned as data");
    assert!(
        matches!(
            error,
            DriverError::Query { ref message, .. }
                if message.contains("Code: 394") && message.contains("Query was cancelled")
        ),
        "graceful server shutdown must preserve the server's cancellation error, got {error:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_committed_insert_with_a_lost_http_ack_is_not_replayed() {
    let (_container, opts) = super::start_clickhouse().await;
    let observer = super::connect(opts.clone()).await;
    observer
        .execute("CREATE TABLE lost_ack_target (id UInt8, value UInt8) ENGINE = MergeTree ORDER BY id")
        .await
        .expect("create target table");
    observer
        .execute("CREATE TABLE lost_ack_audit (id UInt8) ENGINE = MergeTree ORDER BY id")
        .await
        .expect("create independent audit table");
    observer
        .execute(
            "CREATE MATERIALIZED VIEW lost_ack_target_audit TO lost_ack_audit AS
             SELECT id FROM lost_ack_target",
        )
        .await
        .expect("create insert audit view");

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind HTTP proxy");
    let proxy_port = listener.local_addr().expect("proxy address").port();
    let dropped_requests = Arc::new(AtomicUsize::new(0));
    let observed_requests = Arc::clone(&dropped_requests);
    let upstream = format!("{}:{}", opts.host, opts.port);
    let proxy = tokio::spawn(async move {
        loop {
            let Ok((client, _)) = listener.accept().await else {
                return;
            };
            let upstream = upstream.clone();
            let dropped_requests = Arc::clone(&observed_requests);
            tokio::spawn(async move {
                match proxy_clickhouse_connection(client, &upstream, dropped_requests).await {
                    Err(error) if error.kind() != io::ErrorKind::UnexpectedEof => {
                        panic!("ClickHouse lost-ack proxy failed: {error}");
                    }
                    Ok(()) | Err(_) => {}
                }
            });
        }
    });

    let mut proxied_opts = opts.clone();
    proxied_opts.port = proxy_port;
    let connection = super::connect(proxied_opts).await;
    let write = connection.execute("INSERT INTO lost_ack_target VALUES (1, 7)").await;
    assert!(
        matches!(write, Err(DriverError::Disconnected)),
        "a committed ClickHouse INSERT with a lost HTTP response must remain uncertain, got {write:?}"
    );
    assert_eq!(
        dropped_requests.load(Ordering::SeqCst),
        1,
        "proxy drops one INSERT response"
    );

    let recovered = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let Ok(result) = connection
                .query("SELECT id, value FROM lost_ack_target ORDER BY id")
                .await
            {
                break result;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the same HTTP client can run a later query after the lost response");
    assert_eq!(recovered.rows, vec![vec![Value::Int(1), Value::Int(7)]]);

    let target = observer
        .query("SELECT id, value FROM lost_ack_target ORDER BY id")
        .await
        .expect("read native target oracle");
    let audit = observer
        .query("SELECT id FROM lost_ack_audit ORDER BY id")
        .await
        .expect("read independent materialized-view oracle");
    assert_eq!(target.rows, vec![vec![Value::Int(1), Value::Int(7)]]);
    assert_eq!(audit.rows, vec![vec![Value::Int(1)]]);
    assert_eq!(
        dropped_requests.load(Ordering::SeqCst),
        1,
        "reconnect must not resubmit the INSERT"
    );

    proxy.abort();
}

async fn proxy_clickhouse_connection(
    client: TcpStream,
    upstream: &str,
    dropped_requests: Arc<AtomicUsize>,
) -> io::Result<()> {
    let server = TcpStream::connect(upstream).await?;
    let (client_read, mut client_write) = client.into_split();
    let mut client_read = BufReader::new(client_read);
    let (server_read, mut server_write) = server.into_split();
    let mut server_read = BufReader::new(server_read);

    loop {
        let (request, body) = read_http_message(&mut client_read).await?;
        server_write.write_all(&request).await?;
        server_write.flush().await?;
        let (response, _) = read_http_message(&mut server_read).await?;
        if body
            .windows(b"INSERT INTO lost_ack_target".len())
            .any(|window| window == b"INSERT INTO lost_ack_target")
        {
            dropped_requests.fetch_add(1, Ordering::SeqCst);
            return Ok(());
        }
        client_write.write_all(&response).await?;
        client_write.flush().await?;
    }
}

async fn read_http_message(reader: &mut (impl AsyncBufRead + Unpin)) -> io::Result<(Vec<u8>, Vec<u8>)> {
    let mut frame = Vec::new();
    let mut line = Vec::new();
    if reader.read_until(b'\n', &mut line).await? == 0 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "HTTP peer closed"));
    }
    frame.extend_from_slice(&line);
    let mut content_length = 0;
    let mut chunked = false;
    loop {
        line.clear();
        reader.read_until(b'\n', &mut line).await?;
        frame.extend_from_slice(&line);
        if line == b"\r\n" || line == b"\n" {
            break;
        }
        if let Some(separator) = line.iter().position(|byte| *byte == b':') {
            let (name, value) = (&line[..separator], &line[separator + 1..]);
            if name.eq_ignore_ascii_case(b"content-length") {
                content_length = std::str::from_utf8(value)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
                    .trim()
                    .parse::<usize>()
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            } else if name.eq_ignore_ascii_case(b"transfer-encoding") {
                chunked = value
                    .split(|byte| *byte == b',')
                    .any(|value| value.trim_ascii().eq_ignore_ascii_case(b"chunked"));
            }
        }
    }

    let body = if chunked {
        read_chunked_body(reader, &mut frame).await?
    } else {
        let mut body = vec![0; content_length];
        reader.read_exact(&mut body).await?;
        frame.extend_from_slice(&body);
        body
    };
    Ok((frame, body))
}

async fn read_chunked_body(reader: &mut (impl AsyncBufRead + Unpin), frame: &mut Vec<u8>) -> io::Result<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let mut line = Vec::new();
        reader.read_until(b'\n', &mut line).await?;
        let length = std::str::from_utf8(&line)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned();
        frame.extend_from_slice(&line);
        let length =
            usize::from_str_radix(&length, 16).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if length == 0 {
            loop {
                line.clear();
                reader.read_until(b'\n', &mut line).await?;
                frame.extend_from_slice(&line);
                if line == b"\r\n" || line == b"\n" {
                    return Ok(body);
                }
            }
        }
        let mut chunk = vec![0; length + 2];
        reader.read_exact(&mut chunk).await?;
        frame.extend_from_slice(&chunk);
        body.extend_from_slice(&chunk[..length]);
    }
}
