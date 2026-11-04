use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll};

use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// How many bytes the server has sent on one connection.
///
/// tiberius decodes tokens straight off its read buffer, so a request
/// dropped while it waits may have consumed half a token. A response
/// that has not sent a single byte cannot have, and this count is how
/// the driver tells the two apart.
#[derive(Debug, Clone, Default)]
pub(crate) struct ReadTally(Arc<AtomicU64>);

impl ReadTally {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn bytes(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }

    fn add(&self, bytes: usize) {
        let bytes = u64::try_from(bytes).unwrap_or(u64::MAX);
        self.0.fetch_add(bytes, Ordering::SeqCst);
    }
}

/// A transport stream under a concrete type, counting what it reads.
pub(crate) struct TransportIo {
    stream: Box<dyn TransportStream>,
    tally: ReadTally,
}

impl TransportIo {
    pub(crate) fn new(stream: Box<dyn TransportStream>, tally: ReadTally) -> Self {
        Self { stream, tally }
    }
}

impl AsyncRead for TransportIo {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let polled = Pin::new(&mut *this.stream).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &polled {
            this.tally.add(buf.filled().len().saturating_sub(before));
        }
        polled
    }
}

impl AsyncWrite for TransportIo {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.get_mut().stream).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.get_mut().stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.get_mut().stream).poll_shutdown(cx)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.get_mut().stream).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.stream.is_write_vectored()
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    #[tokio::test]
    async fn reads_are_counted_and_writes_are_not() {
        let (client, mut server) = tokio::io::duplex(64);
        let tally = ReadTally::new();
        let mut io = TransportIo::new(Box::new(client), tally.clone());

        io.write_all(b"request").await.unwrap();
        assert_eq!(tally.bytes(), 0);
        server.write_all(b"answer").await.unwrap();
        let mut buffer = [0u8; 6];
        io.read_exact(&mut buffer).await.unwrap();

        assert_eq!(&buffer, b"answer");
        assert_eq!(tally.bytes(), 6);
    }
}
