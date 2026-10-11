use super::*;
use std::io;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_lost_eval_ack_is_not_replayed_after_redis_reconnects() {
    let (_container, host, server_port) = start_redis().await;
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind Redis reply proxy");
    let proxy_port = listener.local_addr().unwrap().port();
    let target_requests = Arc::new(AtomicUsize::new(0));
    let observed_requests = Arc::clone(&target_requests);
    let upstream = format!("{host}:{server_port}");
    let proxy = tokio::spawn(async move {
        loop {
            let Ok((client, _)) = listener.accept().await else {
                return;
            };
            let upstream = upstream.clone();
            let target_requests = Arc::clone(&observed_requests);
            tokio::spawn(async move {
                if let Err(error) = proxy_connection(client, &upstream, target_requests).await
                    && error.kind() != io::ErrorKind::UnexpectedEof
                {
                    panic!("Redis reply proxy failed: {error}");
                }
            });
        }
    });

    let connection = RedisDriver
        .connect(opts("127.0.0.1", proxy_port, "0"))
        .await
        .expect("connect through Redis reply proxy");
    connection.query("PING").await.expect("initial proxy query");

    let write = connection
        .execute(
            "EVAL \"local target=redis.call('INCR',KEYS[1]); redis.call('INCR',KEYS[2]); return target\" \
             2 lost_ack_target lost_ack_audit",
        )
        .await;
    assert!(
        matches!(write, Err(DriverError::Disconnected)),
        "a committed Redis write with a lost reply must stay uncertain, got {write:?}"
    );
    assert_eq!(
        target_requests.load(Ordering::SeqCst),
        1,
        "the proxy drops one committed EVAL reply"
    );

    let recovered = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let Ok(result) = connection.query("PING").await {
                break result;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("Redis connection manager reconnects for the next read");
    assert_eq!(recovered.rows, vec![vec![Value::Text("PONG".into())]]);

    let native = redis::Client::open(format!("redis://{host}:{server_port}/0")).unwrap();
    let mut observer = native.get_multiplexed_async_connection().await.unwrap();
    let target: i64 = redis::cmd("GET")
        .arg("lost_ack_target")
        .query_async(&mut observer)
        .await
        .unwrap();
    let audit: i64 = redis::cmd("GET")
        .arg("lost_ack_audit")
        .query_async(&mut observer)
        .await
        .unwrap();
    assert_eq!((target, audit), (1, 1), "the lost-ack EVAL must execute exactly once");
    assert_eq!(
        target_requests.load(Ordering::SeqCst),
        1,
        "reconnect must not resubmit the EVAL"
    );

    drop(connection);
    proxy.abort();
}

async fn proxy_connection(client: TcpStream, upstream: &str, target_requests: Arc<AtomicUsize>) -> io::Result<()> {
    let server = TcpStream::connect(upstream).await?;
    let (client_read, mut client_write) = client.into_split();
    let mut client_read = BufReader::new(client_read);
    let (server_read, mut server_write) = server.into_split();
    let mut server_read = BufReader::new(server_read);

    loop {
        let (request, args) = read_request(&mut client_read).await?;
        server_write.write_all(&request).await?;
        server_write.flush().await?;
        let response = read_response(&mut server_read).await?;
        if is_lost_ack_eval(&args) {
            target_requests.fetch_add(1, Ordering::SeqCst);
            return Ok(());
        }
        client_write.write_all(&response).await?;
        client_write.flush().await?;
    }
}

async fn read_request(reader: &mut (impl AsyncBufRead + Unpin)) -> io::Result<(Vec<u8>, Vec<Vec<u8>>)> {
    let mut frame = Vec::new();
    let mut line = Vec::new();
    if reader.read_until(b'\n', &mut line).await? == 0 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "client closed"));
    }
    frame.extend_from_slice(&line);
    let count = usize::try_from(parse_length(&line, b'*')?)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid RESP array size"))?;
    let mut args = Vec::with_capacity(count);
    for _ in 0..count {
        line.clear();
        reader.read_until(b'\n', &mut line).await?;
        frame.extend_from_slice(&line);
        let length = usize::try_from(parse_length(&line, b'$')?)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid RESP bulk length"))?;
        let mut bulk = vec![0; length + 2];
        reader.read_exact(&mut bulk).await?;
        args.push(bulk[..length].to_vec());
        frame.extend_from_slice(&bulk);
    }
    Ok((frame, args))
}

async fn read_response(reader: &mut (impl AsyncBufRead + Unpin)) -> io::Result<Vec<u8>> {
    let mut frame = Vec::new();
    let mut pending = 1_usize;
    while pending > 0 {
        pending -= 1;
        let mut line = Vec::new();
        if reader.read_until(b'\n', &mut line).await? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Redis closed"));
        }
        frame.extend_from_slice(&line);
        match line.first().copied() {
            Some(b'$' | b'!' | b'=') => {
                let length = parse_length(&line, line[0])?;
                if length >= 0 {
                    let mut bulk = vec![0; length as usize + 2];
                    reader.read_exact(&mut bulk).await?;
                    frame.extend_from_slice(&bulk);
                }
            }
            Some(b'*' | b'~' | b'>') => {
                let count = parse_length(&line, line[0])?.max(0) as usize;
                pending += count;
            }
            Some(b'%' | b'|') => {
                let count = parse_length(&line, line[0])?.max(0) as usize;
                pending += count * 2;
            }
            Some(b'+' | b'-' | b':' | b',' | b'#' | b'_' | b'(') => {}
            _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "unsupported RESP frame")),
        }
    }
    Ok(frame)
}

fn parse_length(line: &[u8], prefix: u8) -> io::Result<isize> {
    let number = line
        .strip_prefix(&[prefix])
        .and_then(|line| std::str::from_utf8(line).ok())
        .and_then(|line| line.trim().parse::<isize>().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid RESP length"))?;
    Ok(number)
}

fn is_lost_ack_eval(args: &[Vec<u8>]) -> bool {
    args.len() >= 4 && args[0].eq_ignore_ascii_case(b"EVAL") && args[2] == b"2" && args[3] == b"lost_ack_target"
}
