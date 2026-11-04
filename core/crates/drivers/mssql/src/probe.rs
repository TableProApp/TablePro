use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{TlsConfig, TlsMode, Transport};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_rustls::TlsConnector;
use tokio_rustls::rustls::pki_types::ServerName;

use crate::transport_io::{ReadTally, TransportIo};

const TDS_8_ALPN: &[u8] = b"tds/8.0";

/// A TDS 7 pre-login with only the version option (MS-TDS 2.2.6.5): the
/// first packet of a TDS 7.4 login, which a server that allows only
/// strict TLS closes on.
const PRELOGIN: [u8; 20] = [
    0x12, 0x01, 0x00, 0x14, 0x00, 0x00, 0x01, 0x00, // header: PRELOGIN, end of message, 20 bytes
    0x00, 0x00, 0x06, 0x00, 0x06, // VERSION at offset 6, 6 bytes
    0xff, // terminator
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // version 0.0.0.0
];

/// Whether the server answers a TDS 7 pre-login with any byte, on a
/// stream of its own. Nothing past the pre-login is sent.
pub(crate) async fn answers_prelogin(transport: &dyn Transport, within: Duration) -> bool {
    let probing = async {
        let tally = ReadTally::new();
        let mut io = TransportIo::new(transport.open().await.ok()?, tally.clone());
        io.write_all(&PRELOGIN).await.ok()?;
        let mut answer = [0u8; 1];
        let _ = io.read(&mut answer).await;
        Some(tally.bytes() > 0)
    };
    matches!(tokio::time::timeout(within, probing).await, Ok(Some(true)))
}

/// Whether the server answers a strict TLS hello with any byte, on a
/// stream of its own. The certificate goes unchecked, since nothing is
/// sent after the handshake.
pub(crate) async fn answers_strict_hello(transport: &dyn Transport, server_name: &str, within: Duration) -> bool {
    let unchecked = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    let Ok(Some(config)) = tablepro_net::tls::build_client_config(&unchecked) else {
        return false;
    };
    let Ok(name) = ServerName::try_from(server_name.to_owned()) else {
        return false;
    };
    let mut config = (*config).clone();
    config.alpn_protocols = vec![TDS_8_ALPN.to_vec()];
    let connector = TlsConnector::from(Arc::new(config));
    let probing = async {
        let tally = ReadTally::new();
        let io = TransportIo::new(transport.open().await.ok()?, tally.clone());
        let _ = connector.connect(name, io).await;
        Some(tally.bytes() > 0)
    };
    matches!(tokio::time::timeout(within, probing).await, Ok(Some(true)))
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use tablepro_core::{NetworkEndpoint, TransportError, TransportKind, TransportRoute, TransportStream};

    use super::*;

    const WITHIN: Duration = Duration::from_secs(5);

    /// A server that reads what the client sends first, then answers
    /// with `answer` or, when it is empty, hangs up.
    #[derive(Debug)]
    struct Server {
        service: NetworkEndpoint,
        answer: &'static [u8],
    }

    impl Server {
        fn new(answer: &'static [u8]) -> Self {
            Self {
                service: NetworkEndpoint::new("db.example", 1433).unwrap(),
                answer,
            }
        }
    }

    #[async_trait]
    impl Transport for Server {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.service
        }

        fn kind(&self) -> TransportKind {
            TransportKind::DirectTcp
        }

        fn route(&self) -> TransportRoute {
            TransportRoute::Tcp(self.service.clone())
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            let (client, mut server) = tokio::io::duplex(4096);
            let answer = self.answer;
            tokio::spawn(async move {
                let mut first = [0u8; 1];
                let _ = server.read(&mut first).await;
                if !answer.is_empty() {
                    let _ = server.write_all(answer).await;
                }
            });
            Ok(Box::new(client))
        }

        async fn reroute(&self, _endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            Err(TransportError::Timeout {
                phase: tablepro_core::TimeoutPhase::Connect,
            })
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    #[tokio::test]
    async fn a_server_that_answers_the_pre_login_speaks_tds_7() {
        assert!(answers_prelogin(&Server::new(&[0x04, 0x01]), WITHIN).await);
        assert!(!answers_prelogin(&Server::new(&[]), WITHIN).await);
    }

    #[tokio::test]
    async fn a_server_that_answers_the_tls_hello_speaks_strict() {
        // A TLS alert record is an answer, whatever it says.
        let alert: &[u8] = &[0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28];

        assert!(answers_strict_hello(&Server::new(alert), "db.example", WITHIN).await);
        assert!(!answers_strict_hello(&Server::new(&[]), "db.example", WITHIN).await);
    }

    #[test]
    fn the_pre_login_length_is_its_own() {
        assert_eq!(
            usize::from(u16::from_be_bytes([PRELOGIN[2], PRELOGIN[3]])),
            PRELOGIN.len()
        );
    }
}
