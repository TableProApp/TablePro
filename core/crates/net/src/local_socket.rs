use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    LivenessPolicy, LocalSocketProblem, NetworkEndpoint, TimeoutPhase, Transport, TransportError, TransportKind,
    TransportRoute, TransportStream,
};
use tokio::net::UnixStream;

use crate::DirectTcpTransport;

// A server on this machine, through the Unix-domain socket it listens on.
#[derive(Debug, Clone)]
pub struct LocalSocketTransport {
    socket: PathBuf,
    service: NetworkEndpoint,
    liveness: LivenessPolicy,
}

impl LocalSocketTransport {
    pub fn new(socket: PathBuf, service: NetworkEndpoint, liveness: &LivenessPolicy) -> Self {
        Self {
            socket,
            service,
            liveness: *liveness,
        }
    }
}

#[async_trait]
impl Transport for LocalSocketTransport {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        &self.service
    }

    fn kind(&self) -> TransportKind {
        TransportKind::LocalSocket {
            path: self.socket.clone(),
        }
    }

    fn route(&self) -> TransportRoute {
        TransportRoute::UnixSocket(self.socket.clone())
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        match tokio::time::timeout(self.liveness.connect_timeout, UnixStream::connect(&self.socket)).await {
            Ok(Ok(stream)) => Ok(Box::new(stream)),
            Ok(Err(error)) => Err(TransportError::LocalSocket {
                path: self.socket.clone(),
                problem: LocalSocketProblem::from_io(&error),
            }),
            Err(_) => Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect,
            }),
        }
    }

    // A server that redirects the login names a network host, which is dialled directly.
    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        Ok(Arc::new(DirectTcpTransport::new(endpoint, &self.liveness)))
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    use super::*;

    fn transport(socket: PathBuf) -> LocalSocketTransport {
        let service = NetworkEndpoint::new("/run/postgresql", 5432).unwrap();
        LocalSocketTransport::new(socket, service, &LivenessPolicy::DESKTOP)
    }

    #[tokio::test]
    async fn opens_the_socket_and_carries_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join(".s.PGSQL.5432");
        let listener = UnixListener::bind(&socket).unwrap();
        let echo = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0_u8; 4];
            stream.read_exact(&mut buffer).await.unwrap();
            stream.write_all(&buffer).await.unwrap();
        });
        let transport = transport(socket.clone());

        let mut stream = transport.open().await.unwrap();
        stream.write_all(b"ping").await.unwrap();
        let mut answer = [0_u8; 4];
        stream.read_exact(&mut answer).await.unwrap();

        assert_eq!(&answer, b"ping");
        assert_eq!(transport.route(), TransportRoute::UnixSocket(socket.clone()));
        assert_eq!(transport.kind(), TransportKind::LocalSocket { path: socket });
        assert_eq!(transport.service_endpoint().host(), "/run/postgresql");
        echo.await.unwrap();
    }

    #[tokio::test]
    async fn a_missing_socket_and_one_nobody_listens_on_say_so() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("mysqld.sock");
        let stale = dir.path().join("stale.sock");
        drop(std::os::unix::net::UnixListener::bind(&stale).unwrap());

        let error = transport(missing.clone()).open().await.err();
        assert_eq!(
            error,
            Some(TransportError::LocalSocket {
                path: missing,
                problem: LocalSocketProblem::Missing,
            })
        );
        let error = transport(stale.clone()).open().await.err();
        assert_eq!(
            error,
            Some(TransportError::LocalSocket {
                path: stale,
                problem: LocalSocketProblem::Refused,
            })
        );
    }
}
