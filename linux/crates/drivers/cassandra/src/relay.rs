//! A loopback listener that carries each of the client library's
//! connections over the target's transport.
//!
//! scylla dials TCP socket addresses itself and takes no stream, so it
//! cannot reach an SSH forward, which is a Unix socket. It dials this
//! listener instead, and every connection it opens becomes a stream from
//! `Transport::open`. Only sockets this user owns are carried, so the
//! port gives no other local user a way to the server (ADR 0023).

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_core::{DriverError, Transport, TransportError};
use tokio::net::{TcpListener, TcpStream};
use tokio_util::sync::CancellationToken;

use crate::peer_owner::{as_v4, loopback_peer_uid, own_uid};

/// The listener and its connections, all closed when it drops.
#[derive(Debug)]
pub(crate) struct Relay {
    address: SocketAddr,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
}

impl Relay {
    pub(crate) async fn start(transport: Arc<dyn Transport>) -> Result<Self, DriverError> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.map_err(|error| {
            DriverError::Transport(TransportError::Unreachable {
                endpoint: transport.service_endpoint().clone(),
                detail: format!("the local relay could not listen: {error}"),
            })
        })?;
        let address = listener.local_addr().map_err(|error| {
            DriverError::Transport(TransportError::Unreachable {
                endpoint: transport.service_endpoint().clone(),
                detail: format!("the local relay has no address: {error}"),
            })
        })?;
        let stop = CancellationToken::new();
        let failure = Arc::new(Mutex::new(None));
        tokio::spawn(accept(listener, address, transport, stop.clone(), failure.clone()));
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
    listener: TcpListener,
    address: SocketAddr,
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
            Ok((socket, peer)) => {
                tokio::spawn(carry(
                    socket,
                    peer,
                    address,
                    transport.clone(),
                    stop.clone(),
                    failure.clone(),
                ));
            }
            Err(error) => tracing::warn!(%error, "the CQL relay could not accept a connection"),
        }
    }
}

async fn carry(
    mut socket: TcpStream,
    peer: SocketAddr,
    address: SocketAddr,
    transport: Arc<dyn Transport>,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
) {
    if !owned_by_this_user(peer, address).await {
        tracing::warn!("the CQL relay refused a connection another user opened");
        return;
    }
    let mut upstream = match transport.open().await {
        Ok(upstream) => upstream,
        Err(error) => {
            *failure.lock().unwrap_or_else(PoisonError::into_inner) = Some(error);
            return;
        }
    };
    let _ = socket.set_nodelay(true);
    tokio::select! {
        () = stop.cancelled() => {}
        _ = tokio::io::copy_bidirectional(&mut socket, &mut upstream) => {}
    }
}

/// A socket table that cannot be read refuses the connection: the relay
/// never carries one it could not attribute.
async fn owned_by_this_user(peer: SocketAddr, address: SocketAddr) -> bool {
    let (Some(peer), Some(address)) = (as_v4(peer), as_v4(address)) else {
        return false;
    };
    let owner = tokio::task::spawn_blocking(move || loopback_peer_uid(peer, address)).await;
    match owner {
        Ok(Ok(Some(uid))) => uid == own_uid(),
        Ok(Ok(None)) => false,
        Ok(Err(error)) => {
            tracing::warn!(%error, "the CQL relay could not read the socket table");
            false
        }
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::{LivenessPolicy, NetworkEndpoint};
    use tablepro_net::DirectTcpTransport;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
        let relay = Relay::start(transport).await.unwrap();

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
        let relay = Relay::start(Arc::new(DirectTcpTransport::new(endpoint, &LivenessPolicy::DESKTOP)))
            .await
            .unwrap();

        let mut client = TcpStream::connect(relay.address()).await.unwrap();
        let mut byte = [0_u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(5), client.read(&mut byte))
            .await
            .unwrap();

        assert!(
            matches!(read, Ok(0) | Err(_)),
            "the relay kept a refused stream open: {read:?}"
        );
        assert!(matches!(relay.take_failure(), Some(TransportError::Refused { .. })));
    }

    #[tokio::test]
    async fn dropping_the_relay_closes_its_connections() {
        let transport = Arc::new(DirectTcpTransport::new(echo_server().await, &LivenessPolicy::DESKTOP));
        let relay = Relay::start(transport).await.unwrap();
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
