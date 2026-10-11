#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! Protocol fixture pauses SCAN after SELECT has succeeded. No timing guess is
//! used to establish that cancellation occurs inside the temporary database.
use drivers_redis::RedisDriver;
use std::{sync::Arc, time::Duration};
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, OperationControl, TlsConfig, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::Notify,
};

async fn fixture() -> (
    Box<dyn tablepro_core::Connection>,
    Arc<Notify>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let scanning = Arc::new(Notify::new());
    let signal = scanning.clone();
    let server = tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            let signal = signal.clone();
            tokio::spawn(async move {
                let mut socket = BufReader::new(socket);
                let mut db = 0;
                loop {
                    let mut line = String::new();
                    if socket.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let count: usize = line.trim().trim_start_matches('*').parse().unwrap();
                    let mut args = Vec::new();
                    for _ in 0..count {
                        line.clear();
                        socket.read_line(&mut line).await.unwrap();
                        let length: usize = line.trim().trim_start_matches('$').parse().unwrap();
                        let mut bytes = vec![0; length + 2];
                        socket.read_exact(&mut bytes).await.unwrap();
                        args.push(String::from_utf8(bytes[..length].to_vec()).unwrap());
                    }
                    let reply = match args[0].to_uppercase().as_str() {
                        "SELECT" if args[1] == "3" => "-NOPERM selection denied\r\n",
                        "SELECT" => {
                            db = args[1].parse().unwrap();
                            "+OK\r\n"
                        }
                        "SCAN" if db == 2 => {
                            signal.notify_one();
                            std::future::pending::<()>().await;
                            return;
                        }
                        // A dropped selected session must fail, not reconnect
                        // silently onto the configured database and return it.
                        "SCAN" if db == 4 => return,
                        "SCAN" => "*2\r\n$1\r\n0\r\n*0\r\n",
                        "GET" if db == 0 => "$4\r\nhome\r\n",
                        "GET" => "$4\r\naway\r\n",
                        "PING" => "+PONG\r\n",
                        _ => "+OK\r\n",
                    };
                    if socket.get_mut().write_all(reply.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    let conn = RedisDriver
        .connect(ConnectOptions {
            host: "127.0.0.1".into(),
            port,
            database: "0".into(),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    (conn, scanning, server)
}

#[tokio::test]
async fn interrupted_browse_never_changes_normal_command_database() {
    for timeout in [false, true] {
        let (conn, scanning, server) = fixture().await;
        let conn: Arc<dyn tablepro_core::Connection> = conn.into();
        let control = OperationControl::with_timeout(Duration::from_millis(if timeout { 200 } else { 5000 }));
        let cancel = control.cancellation_token().clone();
        let browse_conn = conn.clone();
        let browse = tokio::spawn(async move { browse_conn.fetch_rows_controlled(None, "db2", 0, 10, &control).await });
        tokio::time::timeout(Duration::from_secs(2), scanning.notified())
            .await
            .unwrap();
        if !timeout {
            cancel.cancel();
        }
        let error = tokio::time::timeout(Duration::from_secs(2), browse)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        let DriverError::OperationOutcomeUnknown { source } = error else {
            panic!("{error:?}");
        };
        assert!(if timeout {
            matches!(*source, DriverError::TimedOut)
        } else {
            matches!(*source, DriverError::Cancelled)
        });
        let read = tokio::time::timeout(Duration::from_secs(2), conn.query("GET marker"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(read.rows, vec![vec![Value::Text("home".into())]]);
        assert!(conn.fetch_rows(None, "db3", 0, 10).await.is_err());
        assert!(
            tokio::time::timeout(Duration::from_secs(2), conn.fetch_rows(None, "db4", 0, 10))
                .await
                .expect("browse retried a dropped selected session")
                .is_err()
        );
        assert_eq!(conn.query("GET marker").await.unwrap().rows, read.rows);
        assert!(conn.fetch_rows(None, "db0", 0, 10).await.unwrap().rows.is_empty());
        server.abort();
    }
}
