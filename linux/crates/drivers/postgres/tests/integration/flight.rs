//! A workspace read is one transaction on the wire: its preamble, every
//! query it makes, then its COMMIT.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};

use async_trait::async_trait;
use tablepro_core::meta::TableRef;
use tablepro_core::{
    NetworkEndpoint, TlsConfig, Transport, TransportError, TransportKind, TransportRoute, TransportStream,
    WorkspaceSettings,
};
use tablepro_test_support::conformance::test_liveness;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::support::{CALL, connect_with, direct, options_over, password, setup, start, within};

type Log = Arc<Mutex<Vec<u8>>>;

/// A direct route that keeps what the client writes on each stream.
#[derive(Debug)]
struct RecordingTransport {
    inner: Arc<dyn Transport>,
    streams: Mutex<Vec<Log>>,
}

impl RecordingTransport {
    fn written(&self) -> Vec<Vec<u8>> {
        self.streams
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|log| log.lock().unwrap_or_else(PoisonError::into_inner).clone())
            .collect()
    }
}

#[async_trait]
impl Transport for RecordingTransport {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.inner.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        self.inner.kind()
    }

    fn route(&self) -> TransportRoute {
        self.inner.route()
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        let inner = self.inner.open().await?;
        let log = Log::default();
        self.streams
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(log.clone());
        Ok(Box::new(Recording { inner, log }))
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.inner.reroute(endpoint).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}

struct Recording {
    inner: Box<dyn TransportStream>,
    log: Log,
}

impl AsyncRead for Recording {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Recording {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let written = Pin::new(&mut self.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(count)) = &written
            && let Some(bytes) = buf.get(..*count)
        {
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .extend_from_slice(bytes);
        }
        written
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

fn length(bytes: &[u8]) -> Option<usize> {
    let prefix: [u8; 4] = bytes.get(..4)?.try_into().ok()?;
    usize::try_from(u32::from_be_bytes(prefix)).ok()
}

/// The frontend messages a client wrote, as type and body. The startup
/// packet has no type byte; every message after it has one.
fn messages(written: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut rest = length(written)
        .and_then(|startup| written.get(startup..))
        .unwrap_or_default();
    let mut parsed = Vec::new();
    while let Some((&kind, tail)) = rest.split_first() {
        let Some(len) = length(tail) else { break };
        let (Some(body), Some(next)) = (tail.get(4..len), tail.get(len..)) else {
            break;
        };
        parsed.push((kind, body.to_vec()));
        rest = next;
    }
    parsed
}

fn query_starting(message: &(u8, Vec<u8>), text: &str) -> bool {
    message.0 == b'Q' && message.1.starts_with(text.as_bytes())
}

/// The Parse messages of the last read-only flight on a stream: those
/// sent before its COMMIT, and those sent after it.
fn last_read_flight(messages: &[(u8, Vec<u8>)]) -> Option<(usize, usize)> {
    let start = messages
        .iter()
        .rposition(|message| query_starting(message, "START TRANSACTION READ ONLY"))?;
    let flight = messages.get(start..)?;
    let commit = flight.iter().position(|message| query_starting(message, "COMMIT"))?;
    let parses = |part: &[(u8, Vec<u8>)]| part.iter().filter(|(kind, _)| *kind == b'P').count();
    Some((
        parses(flight.get(..commit).unwrap_or_default()),
        parses(flight.get(commit..).unwrap_or_default()),
    ))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn table_definition_queries_all_run_before_the_commit() {
    let fixture = start().await;
    let liveness = test_liveness();
    let transport = Arc::new(RecordingTransport {
        inner: direct(fixture.host(), fixture.port(), &liveness),
        streams: Mutex::new(Vec::new()),
    });
    let connection = connect_with(options_over(
        transport.clone(),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE parent (id int PRIMARY KEY)",
            "CREATE TABLE child (id int PRIMARY KEY, parent_id int REFERENCES parent (id))",
            "CREATE INDEX child_parent ON child (parent_id)",
        ],
    )
    .await;

    connection
        .fetch_table_definition(&TableRef::new(Some("public".to_owned()), "child"), within(CALL))
        .await
        .expect("the definition");

    let flights: Vec<(usize, usize)> = transport
        .written()
        .iter()
        .filter_map(|written| last_read_flight(&messages(written)))
        .collect();
    assert_eq!(flights.len(), 1, "{flights:?}");
    let (inside, after) = flights.first().copied().unwrap_or_default();
    assert!(inside > 1, "the definition read sent {inside} queries in its flight");
    assert_eq!(after, 0, "{after} queries went out after the COMMIT");
    connection.close().await.expect("a close");
}
