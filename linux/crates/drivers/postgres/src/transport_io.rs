use std::io;
use std::pin::Pin;
use std::task::{Context, Poll, ready};

use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// A transport stream under a concrete type.
///
/// tokio-postgres's TLS traits are generic over the stream, and a boxed
/// trait object there carries an elided lifetime the compiler then asks
/// every async caller to prove for all lifetimes. A named `'static` type
/// has none to prove.
pub(crate) struct TransportIo {
    stream: Box<dyn TransportStream>,
    ending: Ending,
}

/// What a shutdown waits for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ending {
    WriteHalf,
    PeerClose { write_closed: bool },
}

impl TransportIo {
    pub(crate) fn new(stream: Box<dyn TransportStream>) -> Self {
        Self {
            stream,
            ending: Ending::WriteHalf,
        }
    }

    /// A stream whose shutdown returns only once the server has closed
    /// its side too, which the server does for a cancel request only
    /// after it has signalled the backend. libpq's cancel waits the same
    /// way; tokio-postgres's returns once the request is written.
    pub(crate) fn awaiting_close(stream: Box<dyn TransportStream>) -> Self {
        Self {
            stream,
            ending: Ending::PeerClose { write_closed: false },
        }
    }
}

impl AsyncRead for TransportIo {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for TransportIo {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let Ending::PeerClose { write_closed } = &mut this.ending else {
            return Pin::new(&mut *this.stream).poll_shutdown(cx);
        };
        if !*write_closed {
            // A write half that fails to close still leaves the server to
            // close its side, and that close is what is waited for.
            let _ = ready!(Pin::new(&mut *this.stream).poll_shutdown(cx));
            *write_closed = true;
        }
        poll_peer_closed(&mut *this.stream, cx)
    }

    fn poll_write_vectored(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.stream).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.stream.is_write_vectored()
    }
}

/// Read and drop whatever arrives until the server closes. A reset ends
/// the wait as a close does, as it does for libpq.
fn poll_peer_closed(stream: &mut dyn TransportStream, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
    let mut scratch = [0_u8; 64];
    loop {
        let mut buf = ReadBuf::new(&mut scratch);
        match ready!(Pin::new(&mut *stream).poll_read(cx, &mut buf)) {
            Ok(()) if buf.filled().is_empty() => return Poll::Ready(Ok(())),
            Ok(()) => {}
            Err(_) => return Poll::Ready(Ok(())),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_shutdown_awaiting_close_returns_once_the_server_closes() {
        let (client, mut server) = tokio::io::duplex(64);
        let mut stream = TransportIo::awaiting_close(Box::new(client));
        let closing = tokio::spawn(async move { stream.shutdown().await });

        let mut request = Vec::new();
        server
            .read_to_end(&mut request)
            .await
            .expect("the client's end of stream");
        server.write_all(b"ignored").await.expect("a write to the client");
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(
            !closing.is_finished(),
            "the shutdown returned while the server was still open"
        );
        drop(server);

        let closed = tokio::time::timeout(Duration::from_secs(1), closing).await;
        assert!(matches!(closed, Ok(Ok(Ok(())))), "{closed:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn a_plain_shutdown_closes_only_the_write_half() {
        let (client, _server) = tokio::io::duplex(64);
        let mut stream = TransportIo::new(Box::new(client));

        let closed = tokio::time::timeout(Duration::from_secs(1), stream.shutdown()).await;

        assert!(matches!(closed, Ok(Ok(()))), "{closed:?}");
    }
}
