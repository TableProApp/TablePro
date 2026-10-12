use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// A transport stream under a concrete type.
///
/// tokio-postgres's TLS traits are generic over the stream, and a boxed
/// trait object there carries an elided lifetime the compiler then asks
/// every async caller to prove for all lifetimes. A named `'static` type
/// has none to prove.
pub(crate) struct TransportIo(Box<dyn TransportStream>);

impl TransportIo {
    pub(crate) fn new(stream: Box<dyn TransportStream>) -> Self {
        Self(stream)
    }
}

impl AsyncRead for TransportIo {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0).poll_read(cx, buf)
    }
}

impl AsyncWrite for TransportIo {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.0).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.0).poll_shutdown(cx)
    }

    fn poll_write_vectored(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.0).poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.0.is_write_vectored()
    }
}
