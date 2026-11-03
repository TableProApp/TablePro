use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

// russh runs a handshake on a task of its own that a dropped connect cannot reach during key
// exchange, so a hop's stream fails once the connect it belongs to gives up.
pub(crate) struct Abortable {
    inner: Box<dyn TransportStream>,
    aborted: Pin<Box<WaitForCancellationFutureOwned>>,
}

impl Abortable {
    pub fn new(inner: Box<dyn TransportStream>, abort: CancellationToken) -> Self {
        Self {
            inner,
            aborted: Box::pin(abort.cancelled_owned()),
        }
    }

    fn aborted(&mut self, cx: &mut Context<'_>) -> bool {
        self.aborted.as_mut().poll(cx).is_ready()
    }
}

fn gave_up() -> io::Error {
    io::Error::new(io::ErrorKind::ConnectionAborted, "the SSH connect gave up")
}

impl AsyncRead for Abortable {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.aborted(cx) {
            return Poll::Ready(Err(gave_up()));
        }
        Pin::new(&mut this.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Abortable {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        if this.aborted(cx) {
            return Poll::Ready(Err(gave_up()));
        }
        Pin::new(&mut this.inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.aborted(cx) {
            return Poll::Ready(Err(gave_up()));
        }
        Pin::new(&mut this.inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    #[tokio::test]
    async fn a_read_waiting_on_a_silent_peer_ends_when_the_connect_gives_up() {
        let (near, mut far) = tokio::io::duplex(64);
        let abort = CancellationToken::new();
        let mut stream = Abortable::new(Box::new(near), abort.clone());
        far.write_all(b"SSH-").await.unwrap();
        let mut banner = [0_u8; 4];
        stream.read_exact(&mut banner).await.unwrap();

        let waiting = tokio::spawn(async move {
            let mut more = [0_u8; 1];
            stream.read(&mut more).await
        });
        abort.cancel();
        let read = tokio::time::timeout(Duration::from_secs(5), waiting)
            .await
            .unwrap()
            .unwrap();

        assert_eq!(&banner, b"SSH-");
        assert_eq!(read.unwrap_err().kind(), io::ErrorKind::ConnectionAborted);
        drop(far);
    }
}
