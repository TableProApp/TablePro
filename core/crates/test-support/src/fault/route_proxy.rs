use std::io;
use std::sync::Arc;

use tablepro_core::TransportRoute;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::sync::CancellationToken;

use super::fault_transport::FaultDialer;

/// A private socket that relays each connection through the transport's
/// faults: a Unix socket, as an SSH forward is, or on Windows a loopback
/// port.
///
/// An engine whose client library dials `Transport::route()` itself
/// never calls `open()`, so the faults have to sit on the route instead.
#[derive(Debug)]
pub(super) struct RouteProxy {
    route: TransportRoute,
    stop: CancellationToken,
    #[cfg(unix)]
    _dir: tempfile::TempDir,
}

impl RouteProxy {
    pub(super) fn start(dialer: Arc<FaultDialer>) -> io::Result<Self> {
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(io::Error::other("a FaultTransport needs a running tokio runtime"));
        }
        let stop = CancellationToken::new();
        #[cfg(unix)]
        {
            let dir = tempfile::tempdir()?;
            let path = dir.path().join("route.sock");
            let listener = tokio::net::UnixListener::bind(&path)?;
            let accepting = stop.clone();
            tokio::spawn(async move {
                loop {
                    let accepted = tokio::select! {
                        () = accepting.cancelled() => return,
                        accepted = listener.accept() => accepted,
                    };
                    let Ok((client, _)) = accepted else {
                        return;
                    };
                    tokio::spawn(relay(client, dialer.clone(), accepting.clone()));
                }
            });
            Ok(Self {
                route: TransportRoute::UnixSocket(path),
                stop,
                _dir: dir,
            })
        }
        #[cfg(windows)]
        {
            let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
            listener.set_nonblocking(true)?;
            let port = listener.local_addr()?.port();
            let listener = tokio::net::TcpListener::from_std(listener)?;
            let endpoint = tablepro_core::NetworkEndpoint::new("127.0.0.1", port).map_err(io::Error::other)?;
            let accepting = stop.clone();
            tokio::spawn(async move {
                loop {
                    let accepted = tokio::select! {
                        () = accepting.cancelled() => return,
                        accepted = listener.accept() => accepted,
                    };
                    let Ok((client, _)) = accepted else {
                        return;
                    };
                    tokio::spawn(relay(client, dialer.clone(), accepting.clone()));
                }
            });
            Ok(Self {
                route: TransportRoute::Tcp(endpoint),
                stop,
            })
        }
    }

    pub(super) fn route(&self) -> TransportRoute {
        self.route.clone()
    }
}

impl Drop for RouteProxy {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

async fn relay(mut client: impl AsyncRead + AsyncWrite + Unpin, dialer: Arc<FaultDialer>, stop: CancellationToken) {
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
