use std::io;
use std::pin::Pin;
use std::sync::{Arc, OnceLock};
use std::task::{Context, Poll};

use tablepro_core::TlsFailure;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// The first TLS failure a stream met after its handshake.
///
/// Under TLS 1.3 the handshake ends on the client's side before the
/// server has checked the client's certificate, so a server that wants
/// one refuses with an alert the first read meets. redis-rs reports that
/// read only as the connection closing; this keeps what rustls said.
#[derive(Debug, Clone, Default)]
pub(crate) struct TlsFailureSlot(Arc<OnceLock<(TlsFailure, String)>>);

impl TlsFailureSlot {
    pub(crate) fn get(&self) -> Option<(TlsFailure, String)> {
        self.0.get().cloned()
    }

    fn note(&self, error: &io::Error) {
        if let Some(failure) = tablepro_net::tls::classify(error) {
            let _ = self.0.set(failure);
        }
    }
}

pub(crate) struct TlsWatch<S> {
    inner: S,
    slot: TlsFailureSlot,
}

impl<S> TlsWatch<S> {
    pub(crate) fn new(inner: S, slot: TlsFailureSlot) -> Self {
        Self { inner, slot }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for TlsWatch<S> {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let polled = Pin::new(&mut this.inner).poll_read(cx, buf);
        if let Poll::Ready(Err(error)) = &polled {
            this.slot.note(error);
        }
        polled
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for TlsWatch<S> {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let polled = Pin::new(&mut this.inner).poll_write(cx, buf);
        if let Poll::Ready(Err(error)) = &polled {
            this.slot.note(error);
        }
        polled
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let polled = Pin::new(&mut this.inner).poll_flush(cx);
        if let Poll::Ready(Err(error)) = &polled {
            this.slot.note(error);
        }
        polled
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use rustls::AlertDescription;
    use tokio::io::AsyncReadExt;

    use super::*;

    struct Refusing;

    impl AsyncRead for Refusing {
        fn poll_read(self: Pin<&mut Self>, _cx: &mut Context<'_>, _buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Err(io::Error::new(
                io::ErrorKind::InvalidData,
                rustls::Error::AlertReceived(AlertDescription::CertificateRequired),
            )))
        }
    }

    #[tokio::test]
    async fn an_alert_after_the_handshake_is_kept() {
        let slot = TlsFailureSlot::default();
        let mut stream = TlsWatch::new(Refusing, slot.clone());

        let read = stream.read(&mut [0; 8]).await;

        assert!(read.is_err());
        assert_eq!(slot.get().map(|(failure, _)| failure), Some(TlsFailure::HandshakeRejected));
    }
}
