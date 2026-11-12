use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};

use async_trait::async_trait;
use tablepro_core::{NetworkEndpoint, Transport, TransportError, TransportKind, TransportRoute, TransportStream};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Io {
    Wrote,
    Read,
}

/// A transport that counts the round trips on each stream it opens: a
/// burst of writes after the client read something is one more wait on
/// the server. Its route is in-process, so an engine whose client dials
/// the route itself goes through `open()` as well.
#[derive(Debug)]
pub struct RoundTripCounter {
    inner: Arc<dyn Transport>,
    streams: Mutex<Vec<StreamTally>>,
}

/// The round trips one stream has made so far.
#[derive(Debug, Clone, Default)]
pub struct StreamTally(Arc<Mutex<Vec<Io>>>);

impl StreamTally {
    pub fn round_trips(&self) -> usize {
        let log = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        log.iter().filter(|io| **io == Io::Wrote).count()
    }

    fn note(&self, io: Io) {
        let mut log = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if log.last() != Some(&io) {
            log.push(io);
        }
    }
}

impl RoundTripCounter {
    pub fn new(inner: Arc<dyn Transport>) -> Self {
        Self {
            inner,
            streams: Mutex::new(Vec::new()),
        }
    }

    /// Every stream opened so far, oldest first.
    pub fn streams(&self) -> Vec<StreamTally> {
        self.streams.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The round trips of every stream together.
    pub fn round_trips(&self) -> usize {
        self.streams().iter().map(StreamTally::round_trips).sum()
    }
}

#[async_trait]
impl Transport for RoundTripCounter {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.inner.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        self.inner.kind()
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::InProcess
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        let inner = self.inner.open().await?;
        let tally = StreamTally::default();
        self.streams
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(tally.clone());
        Ok(Box::new(Counted { inner, tally }))
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.inner.reroute(endpoint).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}

struct Counted {
    inner: Box<dyn TransportStream>,
    tally: StreamTally,
}

impl AsyncRead for Counted {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let read = Pin::new(&mut self.inner).poll_read(cx, buf);
        if matches!(read, Poll::Ready(Ok(()))) && buf.filled().len() > before {
            self.tally.note(Io::Read);
        }
        read
    }
}

impl AsyncWrite for Counted {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let written = Pin::new(&mut self.inner).poll_write(cx, buf);
        if matches!(written, Poll::Ready(Ok(count)) if count > 0) {
            self.tally.note(Io::Wrote);
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
