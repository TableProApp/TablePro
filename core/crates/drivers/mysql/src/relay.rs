use std::io;
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_core::{Transport, TransportError, TransportStream};
use tablepro_net::{PrivateAddress, PrivateListener};
use tokio_util::sync::CancellationToken;

// sqlx dials an address and takes no stream, so a route only `Transport::open` reaches is carried from here.
#[derive(Debug)]
pub(crate) struct Relay {
    address: PrivateAddress,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
}

impl Relay {
    pub(crate) fn start(transport: Arc<dyn Transport>) -> io::Result<Self> {
        let listener = PrivateListener::bind()?;
        let address = listener.address().clone();
        let stop = CancellationToken::new();
        let failure = Arc::new(Mutex::new(None));
        tokio::spawn(accept(listener, transport, stop.clone(), failure.clone()));
        Ok(Self { address, stop, failure })
    }

    pub(crate) fn address(&self) -> &PrivateAddress {
        &self.address
    }

    // sqlx sees only a closed stream, so this is what a failed login reports instead.
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
    listener: PrivateListener,
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
            Ok(inbound) => {
                tokio::spawn(carry(inbound, transport.clone(), stop.clone(), failure.clone()));
            }
            Err(error) => {
                tracing::warn!(%error, "the MySQL relay stopped taking connections");
                return;
            }
        }
    }
}

async fn carry(
    mut inbound: Box<dyn TransportStream>,
    transport: Arc<dyn Transport>,
    stop: CancellationToken,
    failure: Arc<Mutex<Option<TransportError>>>,
) {
    let mut outbound = match transport.open().await {
        Ok(outbound) => outbound,
        Err(error) => {
            *failure.lock().unwrap_or_else(PoisonError::into_inner) = Some(error);
            return;
        }
    };
    tokio::select! {
        () = stop.cancelled() => {}
        _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound) => {}
    }
}

#[cfg(test)]
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

    async fn dial(address: &PrivateAddress) -> Box<dyn TransportStream> {
        match address {
            #[cfg(unix)]
            PrivateAddress::Unix(path) => Box::new(tokio::net::UnixStream::connect(path).await.unwrap()),
            PrivateAddress::Tcp(address) => Box::new(tokio::net::TcpStream::connect(*address).await.unwrap()),
        }
    }

    #[tokio::test]
    async fn a_connection_reaches_the_server_until_the_relay_drops() {
        let transport = Arc::new(DirectTcpTransport::new(echo_server().await, &LivenessPolicy::DESKTOP));
        let relay = Relay::start(transport).unwrap();

        let mut client = dial(relay.address()).await;
        client.write_all(b"through the relay").await.unwrap();
        let mut reply = [0_u8; 17];
        tokio::time::timeout(Duration::from_secs(5), client.read_exact(&mut reply))
            .await
            .unwrap()
            .unwrap();
        drop(relay);
        let mut byte = [0_u8; 1];
        let after = tokio::time::timeout(Duration::from_secs(5), client.read(&mut byte))
            .await
            .unwrap();

        assert_eq!(&reply, b"through the relay");
        assert!(
            matches!(after, Ok(0) | Err(_)),
            "a connection outlived its relay: {after:?}"
        );
    }
}
