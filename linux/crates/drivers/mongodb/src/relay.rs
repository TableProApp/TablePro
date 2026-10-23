use std::io;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use rustls_pki_types::ServerName;
use tablepro_core::{DriverError, TlsFailure, Transport};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::{JoinHandle, JoinSet};
use tokio_rustls::TlsConnector;

use crate::client_tls::private_dir;

/// TLS the driver negotiates itself on a relayed stream, so it checks the
/// server against the system store and the CA file under the name the
/// connection names.
#[derive(Clone)]
pub(crate) struct RelayTls {
    pub(crate) connector: TlsConnector,
    pub(crate) server_name: ServerName<'static>,
}

/// A private socket the client library dials, where each stream it opens
/// is a stream from the connection's transport, wrapped in TLS here.
///
/// The library dials a Unix socket without TLS, and an SSH forward is a
/// Unix socket. Relaying keeps every stream on the transport, so the
/// forward, its keepalives and what it knows about a closed stream all
/// apply, and TLS still reaches the server past the forward.
pub(crate) struct Relay {
    path: PathBuf,
    _dir: TempDir,
    accepting: JoinHandle<()>,
    failure: FailureSlot,
}

/// The last reason the relay could not reach the server: the transport
/// failed to open a stream, or TLS on it failed. The library sees only a
/// closed socket, so this is what a connect reports instead.
#[derive(Debug, Clone, Default)]
pub(crate) struct FailureSlot(Arc<Mutex<Option<DriverError>>>);

impl FailureSlot {
    pub(crate) fn take(&self) -> Option<DriverError> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).take()
    }

    fn note(&self, error: DriverError) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = Some(error);
    }
}

impl Relay {
    pub(crate) fn start(
        transport: Arc<dyn Transport>,
        tls: Option<RelayTls>,
        handshake_timeout: Duration,
    ) -> io::Result<Self> {
        let dir = private_dir()?;
        let path = dir.path().join("relay.sock");
        let listener = UnixListener::bind(&path)?;
        let failure = FailureSlot::default();
        let slot = failure.clone();
        let accepting = tokio::spawn(async move {
            let mut streams = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => match accepted {
                        Ok((inbound, _)) => {
                            streams.spawn(relay(inbound, transport.clone(), tls.clone(), handshake_timeout, slot.clone()));
                        }
                        Err(error) => {
                            tracing::warn!(%error, "the relay stopped taking streams");
                            break;
                        }
                    },
                    Some(_) = streams.join_next(), if !streams.is_empty() => {}
                }
            }
        });
        Ok(Self {
            path,
            _dir: dir,
            accepting,
            failure,
        })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn failure(&self) -> &FailureSlot {
        &self.failure
    }
}

impl Drop for Relay {
    /// The streams it relays end with it.
    fn drop(&mut self) {
        self.accepting.abort();
    }
}

async fn relay(
    mut inbound: UnixStream,
    transport: Arc<dyn Transport>,
    tls: Option<RelayTls>,
    handshake_timeout: Duration,
    failure: FailureSlot,
) {
    let outbound = match transport.open().await {
        Ok(stream) => stream,
        Err(error) => {
            failure.note(DriverError::Transport(error));
            let _ = inbound.shutdown().await;
            return;
        }
    };
    let Some(tls) = tls else {
        let mut outbound = outbound;
        let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
        return;
    };
    let handshake = tls.connector.connect(tls.server_name.clone(), outbound);
    let secured = match tokio::time::timeout(handshake_timeout, handshake).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            note_tls(&failure, &error);
            let _ = inbound.shutdown().await;
            return;
        }
        Err(_) => {
            let _ = inbound.shutdown().await;
            return;
        }
    };
    let mut secured = Answered::new(secured);
    if let Err(error) = tokio::io::copy_bidirectional(&mut inbound, &mut secured).await {
        // Under TLS 1.3 a server that wants a client certificate refuses
        // it after the handshake: with an alert the first read meets, or,
        // as mongod does, by closing the connection without one.
        match error.kind() == io::ErrorKind::UnexpectedEof && !secured.answered {
            true => failure.note(closed_unanswered()),
            false => note_tls(&failure, &error),
        }
    }
}

/// A server that closed a TLS session it had just agreed to, before
/// answering anything, which is how mongod refuses a client without the
/// certificate it requires.
pub(crate) fn closed_unanswered() -> DriverError {
    DriverError::Tls {
        failure: TlsFailure::HandshakeRejected,
        detail: "the server closed the connection after the TLS handshake without answering; \
                 it may require a client certificate"
            .to_owned(),
    }
}

/// A stream that remembers whether the server sent anything.
struct Answered<S> {
    inner: S,
    answered: bool,
}

impl<S> Answered<S> {
    fn new(inner: S) -> Self {
        Self { inner, answered: false }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for Answered<S> {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let polled = Pin::new(&mut this.inner).poll_read(cx, buf);
        this.answered |= buf.filled().len() > before;
        polled
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Answered<S> {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

fn note_tls(failure: &FailureSlot, error: &io::Error) {
    if let Some((failure_kind, detail)) = tablepro_net::tls::classify(error) {
        failure.note(DriverError::Tls {
            failure: failure_kind,
            detail,
        });
    }
}
