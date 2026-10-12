use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tempfile::TempDir;
use tokio::net::{UnixListener, UnixStream};
use tokio_util::sync::CancellationToken;

use super::fault_transport::FaultDialer;

/// A private Unix socket that relays each connection through the
/// transport's faults.
///
/// An engine whose client library dials `Transport::route()` itself
/// never calls `open()`, so the faults have to sit on the route instead.
#[derive(Debug)]
pub(super) struct RouteProxy {
    path: PathBuf,
    stop: CancellationToken,
    _dir: TempDir,
}

impl RouteProxy {
    pub(super) fn start(dialer: Arc<FaultDialer>) -> io::Result<Self> {
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(io::Error::other("a FaultTransport needs a running tokio runtime"));
        }
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("route.sock");
        let listener = UnixListener::bind(&path)?;
        let stop = CancellationToken::new();
        tokio::spawn(accept(listener, dialer, stop.clone()));
        Ok(Self { path, stop, _dir: dir })
    }

    pub(super) fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for RouteProxy {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

async fn accept(listener: UnixListener, dialer: Arc<FaultDialer>, stop: CancellationToken) {
    loop {
        let accepted = tokio::select! {
            () = stop.cancelled() => return,
            accepted = listener.accept() => accepted,
        };
        let Ok((client, _)) = accepted else {
            return;
        };
        tokio::spawn(relay(client, dialer.clone(), stop.clone()));
    }
}

async fn relay(mut client: UnixStream, dialer: Arc<FaultDialer>, stop: CancellationToken) {
    let upstream = tokio::select! {
        () = stop.cancelled() => return,
        opened = dialer.open() => opened,
    };
    // A failed dial closes the client's side, which is how a refused
    // connection reaches a client that dialled the route itself.
    let Ok(mut upstream) = upstream else {
        return;
    };
    tokio::select! {
        () = stop.cancelled() => {}
        _ = tokio::io::copy_bidirectional(&mut client, &mut upstream) => {}
    }
}
