use std::time::Duration;

use rustls_pki_types::ServerName;
use tablepro_core::{TlsConfig, TlsMode, Transport};
use tokio_rustls::TlsConnector;

use crate::tls::build_client_config;

// The certificate goes unchecked because nothing is sent past the handshake, so no credential can reach the server.
pub async fn serves_tls(transport: &dyn Transport, server_name: &str, within: Duration) -> bool {
    let unchecked = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    let Ok(Some(config)) = build_client_config(&unchecked) else {
        return false;
    };
    let Ok(name) = ServerName::try_from(server_name.to_owned()) else {
        return false;
    };
    let connector = TlsConnector::from(config);
    let probing = async {
        let stream = transport.open().await.ok()?;
        connector.connect(name, stream).await.ok()
    };
    matches!(tokio::time::timeout(within, probing).await, Ok(Some(_)))
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;
    use std::sync::Arc;

    use rcgen::{CertificateParams, KeyPair};
    use rustls::ServerConfig;
    use rustls_pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
    use tablepro_core::{LivenessPolicy, NetworkEndpoint};
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;
    use tokio::task::JoinHandle;
    use tokio_rustls::TlsAcceptor;

    use super::*;
    use crate::DirectTcpTransport;

    const NAME: &str = "db.internal";
    const WITHIN: Duration = Duration::from_secs(5);

    #[derive(Debug, Clone, Copy)]
    enum Plain {
        HangUp,
        Echo,
        Silent,
    }

    fn transport(address: SocketAddr) -> DirectTcpTransport {
        let endpoint = NetworkEndpoint::new("127.0.0.1", address.port()).unwrap();
        DirectTcpTransport::new(endpoint, &LivenessPolicy::DESKTOP)
    }

    fn server_config() -> Arc<ServerConfig> {
        let key = KeyPair::generate().unwrap();
        let certificate = CertificateParams::new(vec![NAME.to_owned()])
            .unwrap()
            .self_signed(&key)
            .unwrap();
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let mut config = ServerConfig::builder_with_provider(Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
            .with_protocol_versions(rustls::DEFAULT_VERSIONS)
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![certificate.der().clone()], key)
            .unwrap();
        // A ticket written after the probe has closed its stream could fail the accept.
        config.send_tls13_tickets = 0;
        Arc::new(config)
    }

    // Returns what the client sent after the handshake.
    async fn tls_server() -> (SocketAddr, JoinHandle<Option<Vec<u8>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let acceptor = TlsAcceptor::from(server_config());
        let serving = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.ok()?;
            let mut tls = acceptor.accept(stream).await.ok()?;
            let mut sent = Vec::new();
            let _ = tls.read_to_end(&mut sent).await;
            Some(sent)
        });
        (address, serving)
    }

    async fn plain_server(plain: Plain) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            match plain {
                Plain::HangUp => {
                    let mut hello = [0u8; 1];
                    let _ = stream.read(&mut hello).await;
                }
                Plain::Echo => {
                    let (mut reading, mut writing) = stream.split();
                    let _ = tokio::io::copy(&mut reading, &mut writing).await;
                }
                // Redis without TLS reads the hello as a command and waits for its newline.
                Plain::Silent => {
                    let mut hello = [0u8; 1];
                    let _ = stream.read(&mut hello).await;
                    std::future::pending::<()>().await;
                }
            }
        });
        address
    }

    #[tokio::test]
    async fn a_tls_server_serves_tls_and_is_sent_nothing_past_the_handshake() {
        let (address, serving) = tls_server().await;

        assert!(serves_tls(&transport(address), NAME, WITHIN).await);
        assert_eq!(serving.await.unwrap(), Some(Vec::new()));
    }

    #[tokio::test]
    async fn a_plain_server_does_not_serve_tls() {
        for plain in [Plain::HangUp, Plain::Echo, Plain::Silent] {
            let address = plain_server(plain).await;

            assert!(
                !serves_tls(&transport(address), NAME, Duration::from_millis(500)).await,
                "{plain:?}"
            );
        }
    }

    #[tokio::test]
    async fn nothing_listening_does_not_serve_tls() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);

        assert!(!serves_tls(&transport(address), NAME, WITHIN).await);
    }
}
