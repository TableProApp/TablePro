use std::io;
use std::net::SocketAddr;
#[cfg(unix)]
use std::path::PathBuf;

use tablepro_core::TransportStream;
#[cfg(unix)]
use tempfile::TempDir;
#[cfg(unix)]
use tokio::net::UnixListener;

#[cfg(not(unix))]
use crate::LoopbackListener;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrivateAddress {
    #[cfg(unix)]
    Unix(PathBuf),
    Tcp(SocketAddr),
}

// For a library that dials an address: a socket in a 0700 directory, else a LoopbackListener; no other user gets in.
#[derive(Debug)]
pub struct PrivateListener {
    address: PrivateAddress,
    listening: Listening,
}

#[derive(Debug)]
enum Listening {
    #[cfg(unix)]
    Unix {
        listener: UnixListener,
        // Dropped after the listener, taking the socket file with it.
        _dir: TempDir,
    },
    #[cfg(not(unix))]
    Loopback(LoopbackListener),
}

impl PrivateListener {
    #[cfg(unix)]
    pub fn bind() -> io::Result<Self> {
        let dir = crate::private_dir("tablepro-relay-")?;
        let path = dir.path().join("relay.sock");
        let listener = UnixListener::bind(&path)?;
        Ok(Self {
            address: PrivateAddress::Unix(path),
            listening: Listening::Unix { listener, _dir: dir },
        })
    }

    #[cfg(not(unix))]
    pub fn bind() -> io::Result<Self> {
        let listener = LoopbackListener::bind()?;
        Ok(Self {
            address: PrivateAddress::Tcp(listener.local_addr()),
            listening: Listening::Loopback(listener),
        })
    }

    pub fn address(&self) -> &PrivateAddress {
        &self.address
    }

    pub async fn accept(&self) -> io::Result<Box<dyn TransportStream>> {
        match &self.listening {
            #[cfg(unix)]
            Listening::Unix { listener, .. } => {
                let (stream, _) = listener.accept().await?;
                Ok(Box::new(stream))
            }
            #[cfg(not(unix))]
            Listening::Loopback(listener) => Ok(Box::new(listener.accept().await?)),
        }
    }
}

#[cfg(test)]
#[cfg(any(unix, windows))]
mod tests {
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    async fn dial(address: &PrivateAddress) -> Box<dyn TransportStream> {
        match address {
            #[cfg(unix)]
            PrivateAddress::Unix(path) => Box::new(tokio::net::UnixStream::connect(path).await.unwrap()),
            PrivateAddress::Tcp(address) => Box::new(tokio::net::TcpStream::connect(*address).await.unwrap()),
        }
    }

    #[tokio::test]
    async fn bytes_cross_a_connection_this_process_dials() {
        let listener = PrivateListener::bind().unwrap();

        let mut client = dial(listener.address()).await;
        let mut accepted = tokio::time::timeout(Duration::from_secs(5), listener.accept())
            .await
            .unwrap()
            .unwrap();
        client.write_all(b"to the relay").await.unwrap();
        let mut inbound = [0_u8; 12];
        accepted.read_exact(&mut inbound).await.unwrap();
        accepted.write_all(b"back").await.unwrap();
        let mut outbound = [0_u8; 4];
        client.read_exact(&mut outbound).await.unwrap();

        assert_eq!(&inbound, b"to the relay");
        assert_eq!(&outbound, b"back");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn the_socket_lives_in_a_private_directory_that_goes_with_the_listener() {
        use std::os::unix::fs::PermissionsExt;

        let listener = PrivateListener::bind().unwrap();
        let PrivateAddress::Unix(path) = listener.address().clone() else {
            panic!("a Unix system listens on a Unix socket");
        };
        let dir = path.parent().unwrap().to_owned();

        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        drop(listener);
        assert!(!dir.exists(), "{} outlived its listener", dir.display());
    }
}
