use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Default)]
struct MysqlProxyState {
    prepare_ack_pending: bool,
    target_statement_id: Option<u32>,
    awaiting_ack: bool,
}

fn is_lost_ack_update(sql: &[u8]) -> bool {
    String::from_utf8_lossy(sql)
        .trim_start()
        .to_ascii_uppercase()
        .starts_with("UPDATE LOST_ACK_TARGET")
}

async fn read_packet<R: tokio::io::AsyncRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Vec<u8>>> {
    use tokio::io::AsyncReadExt;

    let mut header = [0; 4];
    match reader.read_exact(&mut header).await {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let length = usize::from(header[0]) | (usize::from(header[1]) << 8) | (usize::from(header[2]) << 16);
    let mut packet = Vec::with_capacity(4 + length);
    packet.extend_from_slice(&header);
    packet.resize(4 + length, 0);
    reader.read_exact(&mut packet[4..]).await?;
    Ok(Some(packet))
}

async fn mysql_proxy_dropping_update_ack(
    target_host: String,
    target_port: u16,
) -> (
    u16,
    std::sync::Arc<AtomicBool>,
    std::sync::Arc<std::sync::atomic::AtomicUsize>,
    tokio::task::JoinHandle<()>,
) {
    use tokio::io::AsyncWriteExt;
    use tokio::net::{TcpListener, TcpStream};

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind lost-ack proxy");
    let port = listener.local_addr().expect("proxy address").port();
    let dropped_ack = std::sync::Arc::new(AtomicBool::new(false));
    let ack_state = dropped_ack.clone();
    let accepted = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let accept_count = accepted.clone();
    let task = tokio::spawn(async move {
        while let Ok((client, _)) = listener.accept().await {
            accept_count.fetch_add(1, Ordering::SeqCst);
            let host = target_host.clone();
            let dropped_ack = ack_state.clone();
            tokio::spawn(async move {
                let Ok(server) = TcpStream::connect((host.as_str(), target_port)).await else {
                    return;
                };
                let (mut client_read, mut client_write) = client.into_split();
                let (mut server_read, mut server_write) = server.into_split();
                let state = std::sync::Arc::new(std::sync::Mutex::new(MysqlProxyState::default()));
                let client_state = state.clone();
                let forward_client = tokio::spawn(async move {
                    loop {
                        let Ok(Some(packet)) = read_packet(&mut client_read).await else {
                            return;
                        };
                        let payload = &packet[4..];
                        if let Some((&command, body)) = payload.split_first() {
                            let mut state = client_state.lock().expect("proxy state lock");
                            if command == 0x16 && is_lost_ack_update(body) {
                                state.prepare_ack_pending = true;
                            } else if command == 0x03 && is_lost_ack_update(body) {
                                state.awaiting_ack = true;
                            } else if command == 0x17 && body.len() >= 4 {
                                let statement_id = u32::from_le_bytes(body[..4].try_into().expect("4 bytes"));
                                state.awaiting_ack = state.target_statement_id == Some(statement_id);
                            }
                        }
                        if server_write.write_all(&packet).await.is_err() {
                            return;
                        }
                    }
                });

                while let Ok(Some(packet)) = read_packet(&mut server_read).await {
                    let payload = &packet[4..];
                    let drop_ack = {
                        let mut state = state.lock().expect("proxy state lock");
                        if state.prepare_ack_pending && payload.first() == Some(&0x00) && payload.len() >= 5 {
                            state.target_statement_id = Some(u32::from_le_bytes(
                                payload[1..5].try_into().expect("4-byte statement id"),
                            ));
                            state.prepare_ack_pending = false;
                            false
                        } else if state.awaiting_ack && payload.first() == Some(&0x00) {
                            state.awaiting_ack = false;
                            true
                        } else {
                            false
                        }
                    };
                    if drop_ack {
                        dropped_ack.store(true, Ordering::SeqCst);
                        let _ = client_write.shutdown().await;
                        forward_client.abort();
                        return;
                    }
                    if client_write.write_all(&packet).await.is_err() {
                        break;
                    }
                }
                forward_client.abort();
            });
        }
    });
    (port, dropped_ack, accepted, task)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect() {
    use secrecy::ExposeSecret;

    let (_container, opts) = super::shared_container::start_mysql_durable().await;
    let observer = connect(opts.clone()).await;
    assert_eq!(
        observer
            .query("SELECT @@GLOBAL.innodb_flush_log_at_trx_commit, @@GLOBAL.innodb_doublewrite, @@GLOBAL.sync_binlog")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1), Value::Text("ON".into()), Value::Int(1)]],
    );
    observer
        .execute("CREATE TABLE lost_ack_target (id INT PRIMARY KEY, value INT NOT NULL)")
        .await
        .unwrap();
    observer
        .execute("CREATE TABLE lost_ack_audit (target_id INT NOT NULL)")
        .await
        .unwrap();
    let fixture = sqlx::mysql::MySqlPoolOptions::new()
        .connect_with(
            sqlx::mysql::MySqlConnectOptions::new()
                .host(&opts.host)
                .port(opts.port)
                .username(&opts.username)
                .password(opts.password.expose_secret())
                .database(&opts.database)
                .ssl_mode(sqlx::mysql::MySqlSslMode::Disabled),
        )
        .await
        .unwrap();
    sqlx::raw_sql(
        "CREATE TRIGGER lost_ack_record_update AFTER UPDATE ON lost_ack_target
         FOR EACH ROW INSERT INTO lost_ack_audit VALUES (NEW.id)",
    )
    .execute(&fixture)
    .await
    .unwrap();
    fixture.close().await;
    observer
        .execute("INSERT INTO lost_ack_target VALUES (1, 0)")
        .await
        .unwrap();

    let (proxy_port, dropped_ack, accepted, proxy_task) =
        mysql_proxy_dropping_update_ack(opts.host.clone(), opts.port).await;
    let mut proxied_opts = opts;
    proxied_opts.host = "127.0.0.1".into();
    proxied_opts.port = proxy_port;
    let connection = MysqlDriver.connect(proxied_opts).await.expect("connect through proxy");
    let write = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        connection.execute("UPDATE lost_ack_target SET value = value + 1 WHERE id = 1"),
    )
    .await
    .expect("lost acknowledgement must not hang");
    assert!(
        dropped_ack.load(Ordering::SeqCst),
        "proxy must drop the UPDATE acknowledgement"
    );
    assert!(
        matches!(write, Err(DriverError::Disconnected)),
        "a write with a lost acknowledgement must remain uncertain, got {write:?}"
    );

    let recovered = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            match connection.query("SELECT value FROM lost_ack_target WHERE id = 1").await {
                Ok(result) => break result,
                Err(DriverError::Disconnected) => tokio::time::sleep(std::time::Duration::from_millis(50)).await,
                Err(error) => panic!("pool recovery query failed unexpectedly: {error:?}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "pool must recover within five seconds; proxy accepted {} connections",
            accepted.load(Ordering::SeqCst)
        )
    });
    assert!(
        accepted.load(Ordering::SeqCst) >= 2,
        "pool recovery must establish a new TCP connection"
    );
    assert_eq!(recovered.rows, vec![vec![Value::Int(1)]]);
    let audit = observer
        .query("SELECT target_id FROM lost_ack_audit ORDER BY target_id")
        .await
        .unwrap();
    assert_eq!(
        audit.rows,
        vec![vec![Value::Int(1)]],
        "trigger audit is the replay oracle"
    );

    drop(connection);
    proxy_task.abort();
}
