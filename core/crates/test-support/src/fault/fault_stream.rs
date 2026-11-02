use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use tablepro_core::TransportStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::fault_state::FaultState;

/// One stream through a `FaultTransport`.
///
/// A black hole is what a dropped route looks like from the client:
/// writes are accepted and go nowhere, and reads never complete. Nothing
/// closes the socket, so only the driver's own deadlines can notice.
pub(super) struct FaultStream {
    inner: Box<dyn TransportStream>,
    state: Arc<FaultState>,
    reads_stalled: bool,
    written_tail: Vec<u8>,
}

impl FaultStream {
    pub(super) fn new(inner: Box<dyn TransportStream>, state: Arc<FaultState>) -> Self {
        Self {
            inner,
            state,
            reads_stalled: false,
            written_tail: Vec::new(),
        }
    }

    /// Look for the armed pattern in what was just written, including
    /// across the boundary with the previous write, since a driver may
    /// split one message over several writes.
    fn watch_written(&mut self, written: &[u8]) {
        let Some(pattern_len) = self.state.stall_pattern_len() else {
            self.written_tail.clear();
            return;
        };
        self.written_tail.extend_from_slice(written);
        if self.state.take_stall(&self.written_tail) {
            self.reads_stalled = true;
        }
        let keep = pattern_len.saturating_sub(1);
        let excess = self.written_tail.len().saturating_sub(keep);
        self.written_tail.drain(..excess);
    }
}

impl AsyncRead for FaultStream {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        if self.reads_stalled || self.state.is_black_holed() {
            return Poll::Pending;
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for FaultStream {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        if self.state.is_black_holed() {
            return Poll::Ready(Ok(buf.len()));
        }
        let written = Pin::new(&mut self.inner).poll_write(cx, buf);
        if let Poll::Ready(Ok(count)) = &written
            && let Some(bytes) = buf.get(..*count)
        {
            self.watch_written(bytes);
        }
        written
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.state.is_black_holed() {
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.state.is_black_holed() {
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
