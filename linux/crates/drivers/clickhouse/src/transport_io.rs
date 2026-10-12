use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use hyper_util::client::legacy::connect::{Connected, Connection};
use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// A transport stream under a concrete type hyper's pool can hold.
///
/// hyper-util's client asks every connection it pools for `Connected`
/// metadata, which a boxed trait object cannot provide, so the stream is
/// wrapped once here and the same type serves a TCP socket and the
/// OpenSSH forward's Unix socket alike.
pub(crate) struct TransportIo(Box<dyn TransportStream>);

impl TransportIo {
    pub(crate) fn new(stream: Box<dyn TransportStream>) -> Self {
        Self(stream)
    }
}

impl Connection for TransportIo {
    fn connected(&self) -> Connected {
        Connected::new()
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
