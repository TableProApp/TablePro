use std::io;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

use mongodb::bson::{Document, doc};
use tablepro_core::{DatabaseDriver, DriverError, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::{MongodbDriver, opts, start_mongo};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect() {
    let (_container, host, port) = start_mongo().await;
    let (target, profiler) = prepare_observer(&host, port).await;

    let (proxy_port, dropped_ack, update_requests, proxy_task) = start_proxy(host, port).await;
    let connection = MongodbDriver
        .connect(opts("127.0.0.1", proxy_port, "appdb"))
        .await
        .expect("connect through MongoDB reply proxy");
    let write = connection
        .execute_params(
            "UPDATE lost_ack_target SET value = ? WHERE _id = ?",
            &[Value::Int(1), Value::Text("target".into())],
        )
        .await;
    assert!(
        dropped_ack.load(Ordering::SeqCst),
        "proxy must drop the processed update acknowledgement"
    );
    assert!(
        matches!(write, Err(DriverError::Disconnected)),
        "a write with a lost acknowledgement must stay uncertain, got {write:?}"
    );

    let recovered = connection
        .query("db.lost_ack_target.find({})")
        .await
        .expect("a later operation reconnects the MongoDB client");
    assert_eq!(recovered.rows.len(), 1);
    let row = target
        .find_one(doc! { "_id": "target" })
        .await
        .expect("read native target row")
        .expect("target row remains");
    assert_eq!(row.get("value"), Some(&mongodb::bson::Bson::Int64(1)), "{row:?}");
    assert_eq!(
        update_requests.load(Ordering::SeqCst),
        1,
        "proxy observed one update request"
    );

    let profile_record = profiler
        .find_one(doc! {})
        .await
        .expect("read MongoDB profiler")
        .expect("MongoDB records the committed update");
    let update_count = profiler
        .count_documents(doc! {
            "op": "update",
            "ns": "appdb.lost_ack_target",
            "command.q._id": "target",
            "command.u.$set.value": 1,
        })
        .await
        .expect("count native profiler records");
    assert_eq!(update_count, 1, "the independent profiler record: {profile_record:?}");

    proxy_task.abort();
}

async fn prepare_observer(host: &str, port: u16) -> (mongodb::Collection<Document>, mongodb::Collection<Document>) {
    let native = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native MongoDB observer");
    let database = native.database("appdb");
    database
        .collection::<Document>("lost_ack_target")
        .insert_one(doc! { "_id": "target", "value": 0 })
        .await
        .expect("seed target row");
    database
        .run_command(doc! { "profile": 2 })
        .await
        .expect("enable independent profiler audit");
    (
        database.collection("lost_ack_target"),
        database.collection("system.profile"),
    )
}

async fn start_proxy(
    host: String,
    server_port: u16,
) -> (u16, Arc<AtomicBool>, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind MongoDB reply proxy");
    let proxy_port = listener.local_addr().expect("proxy address").port();
    let dropped_ack = Arc::new(AtomicBool::new(false));
    let update_requests = Arc::new(AtomicUsize::new(0));
    let task_dropped_ack = Arc::clone(&dropped_ack);
    let task_update_requests = Arc::clone(&update_requests);
    let task = tokio::spawn(async move {
        loop {
            let Ok((client, _)) = listener.accept().await else {
                return;
            };
            let upstream = format!("{host}:{server_port}");
            let dropped_ack = Arc::clone(&task_dropped_ack);
            let update_requests = Arc::clone(&task_update_requests);
            tokio::spawn(async move {
                if let Err(error) = proxy_connection(client, &upstream, dropped_ack, update_requests).await
                    && error.kind() != io::ErrorKind::UnexpectedEof
                {
                    panic!("MongoDB reply proxy failed: {error}");
                }
            });
        }
    });
    (proxy_port, dropped_ack, update_requests, task)
}

async fn proxy_connection(
    client: TcpStream,
    upstream: &str,
    dropped_ack: Arc<AtomicBool>,
    update_requests: Arc<AtomicUsize>,
) -> io::Result<()> {
    let upstream = TcpStream::connect(upstream).await?;
    let (mut client_read, mut client_write) = client.into_split();
    let (mut server_read, mut server_write) = upstream.into_split();
    let mut update_request_id = None;
    loop {
        tokio::select! {
            message = read_message(&mut client_read) => {
                let message = message?;
                if update_collection(&message).as_deref() == Some("lost_ack_target") {
                    update_request_id = Some(i32::from_le_bytes(message[4..8].try_into().expect("request ID")));
                    update_requests.fetch_add(1, Ordering::SeqCst);
                }
                server_write.write_all(&message).await?;
            }
            message = read_message(&mut server_read) => {
                let message = message?;
                let response_to = i32::from_le_bytes(message[8..12].try_into().expect("response ID"));
                if update_request_id == Some(response_to) {
                    dropped_ack.store(true, Ordering::SeqCst);
                    return Ok(());
                }
                client_write.write_all(&message).await?;
            }
        }
    }
}

async fn read_message<R: AsyncRead + Unpin>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut header = [0; 16];
    reader.read_exact(&mut header).await?;
    let length = i32::from_le_bytes(header[..4].try_into().expect("message length"));
    if !(21..=48_000_000).contains(&length) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid MongoDB message length",
        ));
    }
    let mut message = Vec::with_capacity(length as usize);
    message.extend_from_slice(&header);
    message.resize(length as usize, 0);
    reader.read_exact(&mut message[16..]).await?;
    Ok(message)
}

fn update_collection(message: &[u8]) -> Option<String> {
    if i32::from_le_bytes(message[12..16].try_into().ok()?) != 2013 || message[20] != 0 {
        return None;
    }
    let document_length = i32::from_le_bytes(message[21..25].try_into().ok()?) as usize;
    let document_end = 21usize.checked_add(document_length)?;
    let command: Document = mongodb::bson::from_slice(message.get(21..document_end)?).ok()?;
    command.get_str("update").ok().map(str::to_owned)
}
