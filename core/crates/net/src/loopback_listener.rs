use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};

use crate::loopback_owner::loopback_peer_is_ours;

const ACCEPT_RETRY: Duration = Duration::from_millis(50);

// A port on 127.0.0.1 that hands out only the connections `loopback_peer_is_ours` confirms.
#[derive(Debug)]
pub struct LoopbackListener {
    listener: TcpListener,
    address: SocketAddr,
}

impl LoopbackListener {
    pub fn bind() -> io::Result<Self> {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let listener = TcpListener::from_std(listener)?;
        let address = listener.local_addr()?;
        Ok(Self { listener, address })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.address
    }

    // Not cancel safe: a connection taken while its owner is checked closes with the dropped future.
    // Waits past accept errors: any local user can reset a queued connection or use up sockets for a moment.
    pub async fn accept(&self) -> io::Result<TcpStream> {
        loop {
            let (stream, peer) = match self.listener.accept().await {
                Ok(accepted) => accepted,
                Err(error) => {
                    tracing::debug!(%error, "a loopback connection was lost before it was accepted");
                    tokio::time::sleep(ACCEPT_RETRY).await;
                    continue;
                }
            };
            let local = self.address;
            let owned = tokio::task::spawn_blocking(move || loopback_peer_is_ours(peer, local))
                .await
                .unwrap_or_else(|error| Err(io::Error::other(error)));
            match owned {
                Ok(true) => {
                    let _ = stream.set_nodelay(true);
                    return Ok(stream);
                }
                Ok(false) => tracing::warn!(%peer, "refused a loopback connection another owner opened"),
                Err(error) => tracing::warn!(%peer, %error, "refused a loopback connection whose owner is unknown"),
            }
        }
    }
}

#[cfg(test)]
#[cfg(any(target_os = "linux", windows))]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    #[tokio::test]
    async fn a_connection_this_process_opens_is_accepted() {
        let listener = LoopbackListener::bind().unwrap();
        let mut client = TcpStream::connect(listener.local_addr()).await.unwrap();
        let mut accepted = tokio::time::timeout(Duration::from_secs(5), listener.accept())
            .await
            .unwrap()
            .unwrap();

        client.write_all(b"ours").await.unwrap();
        let mut read = [0_u8; 4];
        accepted.read_exact(&mut read).await.unwrap();

        assert_eq!(&read, b"ours");
        assert_eq!(listener.local_addr().ip(), Ipv4Addr::LOCALHOST);
    }
}
