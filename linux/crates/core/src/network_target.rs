use std::sync::Arc;

use crate::credentials::Credentials;
use crate::tls_config::TlsConfig;
use crate::transport::Transport;

/// A server reached over the network, and how to log in to it.
///
/// The transport already knows the route, so a driver never sees
/// whether it is talking to the server directly or through an SSH
/// forward. Trust is not carried here: each driver builds its own from
/// `tls`, because the engines' TLS stacks accept trust anchors in
/// different forms.
#[derive(Debug, Clone)]
pub struct NetworkTarget {
    pub transport: Arc<dyn Transport>,
    pub credentials: Credentials,
    pub database: Option<String>,
    pub tls: TlsConfig,
}

impl NetworkTarget {
    /// The name the server's certificate is checked against. Through a
    /// tunnel the socket points at a local forward, so the name comes
    /// from the service the forward reaches, never from the socket.
    pub fn tls_server_name(&self) -> &str {
        self.tls
            .server_name
            .as_deref()
            .unwrap_or_else(|| self.transport.service_endpoint().host())
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;

    use super::*;
    use crate::{NetworkEndpoint, TransportError, TransportKind, TransportRoute, TransportStream};

    #[derive(Debug)]
    struct Forward {
        service: NetworkEndpoint,
    }

    #[async_trait]
    impl Transport for Forward {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.service
        }

        fn kind(&self) -> TransportKind {
            TransportKind::SshForward {
                destination: "bastion".to_owned(),
            }
        }

        fn route(&self) -> TransportRoute {
            TransportRoute::UnixSocket("/run/user/1000/forward.sock".into())
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            let (client, _server) = tokio::io::duplex(64);
            Ok(Box::new(client))
        }

        async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            Ok(Arc::new(Self { service: endpoint }))
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    fn target(server_name: Option<&str>) -> Option<NetworkTarget> {
        let service = NetworkEndpoint::new("db.internal.example", 5432).ok()?;
        let mut tls = TlsConfig::verify_full();
        tls.server_name = server_name.map(str::to_owned);
        Some(NetworkTarget {
            transport: Arc::new(Forward { service }),
            credentials: Credentials::Integrated,
            database: None,
            tls,
        })
    }

    #[test]
    fn a_tunnelled_server_is_verified_by_its_own_name() {
        let target = target(None).expect("a valid endpoint");

        assert_eq!(target.tls_server_name(), "db.internal.example");
    }

    #[test]
    fn an_explicit_server_name_wins() {
        let target = target(Some("db.example.com")).expect("a valid endpoint");

        assert_eq!(target.tls_server_name(), "db.example.com");
    }
}
