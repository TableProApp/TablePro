//! A loopback listener that carries each of the client library's
//! connections over the target's transport.
//!
//! scylla dials TCP socket addresses itself and takes no stream, so it
//! cannot reach an SSH forward. It dials this listener instead, and every
//! connection it opens becomes a stream from `Transport::open`. Only
//! sockets this user owns, or on Windows this process, are carried, so
//! the port gives no other local user a way to the server (ADR 0023).

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_core::{DriverError, Transport, TransportError};
use tablepro_net::LoopbackListener;
use tokio::net::TcpStream;
use tokio_util::sync::CancellationToken;

/// The listener and its connections, all closed when it drops.
#[derive(Debug)]
pub(crate) struct Relay {
    address: SocketAddr,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
}

impl Relay {
    pub(crate) fn start(transport: Arc<dyn Transport>) -> Result<Self, DriverError> {
        let listener = LoopbackListener::bind().map_err(|error| {
            DriverError::Transport(TransportError::Unreachable {
                endpoint: transport.service_endpoint().clone(),
                detail: format!("the local relay could not listen: {error}"),
            })
        })?;
        let address = listener.local_addr();
        let stop = CancellationToken::new();
        let failure = Arc::new(Mutex::new(None));
        tokio::spawn(accept(listener, transport, stop.clone(), failure.clone()));
        Ok(Self { address, stop, failure })
    }

    pub(crate) fn address(&self) -> SocketAddr {
        self.address
    }

    /// Why the transport last failed to open a stream, which says more
    /// than the closed connection the client library saw.
    pub(crate) fn take_failure(&self) -> Option<TransportError> {
        self.failure.lock().unwrap_or_else(PoisonError::into_inner).take()
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

async fn accept(
    listener: LoopbackListener,
    transport: Arc<dyn Transport>,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
) {
    loop {
        let accepted = tokio::select! {
            () = stop.cancelled() => return,
            accepted = listener.accept() => accepted,
        };
        match accepted {
            Ok(socket) => {
                tokio::spawn(carry(socket, transport.clone(), stop.clone(), failure.clone()));
            }
            Err(error) => tracing::warn!(%error, "the CQL relay could not accept a connection"),
        }
    }
}

async fn carry(
    mut socket: TcpStream,
    transport: Arc<dyn Transport>,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
) {
    let mut upstream = match transport.open().await {
        Ok(upstream) => upstream,
        Err(error) => {
            *failure.lock().unwrap_or_else(PoisonError::into_inner) = Some(error);
            return;
        }
    };
    tokio::select! {
        () = stop.cancelled() => {}
        _ = tokio::io::copy_bidirectional(&mut socket, &mut upstream) => {}
    }
}

// Only Linux and Windows name a loopback connection's owner; elsewhere the relay serves no one.
#[cfg(test)]
#[cfg(any(target_os = "linux", windows))]
mod tests {
    use std::net::Ipv4Addr;
    use std::time::Duration;

    use tablepro_core::{LivenessPolicy, NetworkEndpoint};
    use tablepro_net::DirectTcpTransport;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;

    async fn echo_server() -> NetworkEndpoint {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut reader, mut writer) = stream.split();
                    let _ = tokio::io::copy(&mut reader, &mut writer).await;
                });
            }
        });
        NetworkEndpoint::new("127.0.0.1", port).unwrap()
    }

    #[tokio::test]
    async fn a_connection_of_this_user_reaches_the_server() {
        let transport = Arc::new(DirectTcpTransport::new(echo_server().await, &LivenessPolicy::DESKTOP));
        let relay = Relay::start(transport).unwrap();

        let mut client = TcpStream::connect(relay.address()).await.unwrap();
        client.write_all(b"through the relay").await.unwrap();
        let mut reply = [0_u8; 17];
        tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut reply))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(&reply, b"through the relay");
    }

    #[tokio::test]
    async fn a_failed_open_is_kept_for_the_connect_to_report() {
        let unused = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let endpoint = NetworkEndpoint::new("127.0.0.1", unused.local_addr().unwrap().port()).unwrap();
        drop(unused);
        let relay = Relay::start(Arc::new(DirectTcpTransport::new(endpoint, &LivenessPolicy::DESKTOP))).unwrap();

        let mut client = TcpStream::connect(relay.address()).await.unwrap();
        let mut byte = [0_u8; 1];
        // Windows retries a refused connect for about two seconds, longer on a busy runner, so
        // the wait is the transport's own connect timeout plus room to close the stream.
        let within = LivenessPolicy::DESKTOP.connect_timeout + Duration::from_secs(5);
        let read = tokio::time::timeout(within, client.read(&mut byte)).await.unwrap();

        assert!(
            matches!(read, Ok(0) | Err(_)),
            "the relay kept a refused stream open: {read:?}"
        );
        assert!(matches!(relay.take_failure(), Some(TransportError::Refused { .. })));
    }

    #[tokio::test]
    async fn dropping_the_relay_closes_its_connections() {
        let transport = Arc::new(DirectTcpTransport::new(echo_server().await, &LivenessPolicy::DESKTOP));
        let relay = Relay::start(transport).unwrap();
        let mut client = TcpStream::connect(relay.address()).await.unwrap();
        client.write_all(b"x").await.unwrap();
        let mut byte = [0_u8; 1];
        client.read_exact(&mut byte).await.unwrap();

        drop(relay);
        let read = tokio::time::timeout(Duration::from_secs(5), client.read(&mut byte))
            .await
            .unwrap();

        assert!(
            matches!(read, Ok(0) | Err(_)),
            "a connection outlived its relay: {read:?}"
        );
    }
}
