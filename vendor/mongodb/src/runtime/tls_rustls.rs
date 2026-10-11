use std::{
    convert::TryFrom,
    fs::File,
    io::{BufReader, Seek},
    sync::Arc,
};

#[cfg(feature = "rustls-tls-aws-lc")]
use rustls::crypto::aws_lc_rs as provider;
#[cfg(all(feature = "rustls-tls", not(feature = "rustls-tls-aws-lc")))]
use rustls::crypto::ring as provider;
use rustls::{
    client::ClientConfig,
    pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer, ServerName},
    Error as TlsError,
    RootCertStore,
};

use tokio::io::{AsyncRead, AsyncWrite};
use tokio_rustls::TlsConnector;
use webpki_roots::TLS_SERVER_ROOTS;

use crate::{
    client::options::TlsOptions,
    error::{ErrorKind, Result},
};

pub(crate) type TlsStream<T> = tokio_rustls::client::TlsStream<T>;

/// Configuration required to use TLS. Creating this is expensive, so its best to cache this value
/// and reuse it for multiple connections.
#[derive(Clone)]
pub(crate) struct TlsConfig {
    connector: TlsConnector,
    verify_hostname: Option<String>,
}

impl TlsConfig {
    /// Create a new `TlsConfig` from the provided options from the user.
    /// This operation is expensive, so the resultant `TlsConfig` should be cached.
    pub(crate) fn new(options: TlsOptions) -> Result<TlsConfig> {
        let verify_hostname = options.verify_hostname.clone();
        let mut tls_config = make_rustls_config(options)?;
        tls_config.enable_sni = true;

        let connector: TlsConnector = Arc::new(tls_config).into();
        Ok(TlsConfig {
            connector,
            verify_hostname,
        })
    }
}

pub(crate) async fn tls_connect<T: AsyncRead + AsyncWrite + Unpin>(
    host: &str,
    tcp_stream: T,
    cfg: &TlsConfig,
) -> Result<TlsStream<T>> {
    let verify_host = cfg.verify_hostname.as_deref().unwrap_or(host);
    let name = ServerName::try_from(verify_host)
        .map_err(|e| ErrorKind::DnsResolve {
            message: format!("could not resolve {:?}: {e}", crate::error::Redact(verify_host)),
        })?
        .to_owned();

    let conn = cfg
        .connector
        .connect_with(name, tcp_stream, |c| {
            c.set_buffer_limit(None);
        })
        .await?;
    Ok(conn)
}

/// Converts `TlsOptions` into a rustls::ClientConfig.
fn make_rustls_config(cfg: TlsOptions) -> Result<rustls::ClientConfig> {
    let mut store = RootCertStore::empty();
    if let Some(path) = cfg.ca_file_path {
        let ders = CertificateDer::pem_file_iter(&path)
            .map_err(|err| ErrorKind::InvalidTlsConfig {
                message: format!(
                    "Unable to parse PEM-encoded root certificate from {}: {err}",
                    path.display()
                ),
            })?
            .flatten();
        store.add_parsable_certificates(ders);
    } else {
        store.extend(TLS_SERVER_ROOTS.iter().cloned());
    }

    let config_builder = ClientConfig::builder_with_provider(provider::default_provider().into())
        .with_safe_default_protocol_versions()
        .map_err(|e| ErrorKind::InvalidTlsConfig {
            message: format!("built-in provider should support default protocol versions: {e}"),
        })?
        .with_root_certificates(store);

    let mut config = if let Some(path) = cfg.cert_key_file_path {
        let mut file = BufReader::new(File::open(&path)?);
        let mut certs = vec![];

        for cert in CertificateDer::pem_reader_iter(&mut file) {
            let cert = cert.map_err(|error| ErrorKind::InvalidTlsConfig {
                message: format!(
                    "Unable to parse PEM-encoded client certificate from {}: {error}",
                    path.display(),
                ),
            })?;
            certs.push(cert);
        }

        file.rewind()?;
        let key = 'key: {
            #[cfg(feature = "cert-key-password")]
            if let Some(key_pw) = cfg.tls_certificate_key_file_password.as_deref() {
                use rustls::pki_types::PrivatePkcs8KeyDer;
                use std::io::Read;
                let mut contents = vec![];
                file.read_to_end(&mut contents)?;
                break 'key PrivatePkcs8KeyDer::from(super::pem::decrypt_private_key(
                    &contents, key_pw,
                )?)
                .into();
            }
            match PrivateKeyDer::from_pem_reader(&mut file) {
                Ok(key) => break 'key key,
                Err(err) => {
                    return Err(ErrorKind::InvalidTlsConfig {
                        message: format!(
                            "Unable to parse PEM-encoded item from {}: {err}",
                            path.display(),
                        ),
                    }
                    .into())
                }
            }
        };

        config_builder
            .with_client_auth_cert(certs, key)
            .map_err(|error| ErrorKind::InvalidTlsConfig {
                message: error.to_string(),
            })?
    } else {
        config_builder.with_no_client_auth()
    };

    if let Some(true) = cfg.allow_invalid_certificates {
        // nosemgrep: rustls-dangerous
        config // mongodb rating: No Fix Needed
            .dangerous()
            .set_certificate_verifier(Arc::new(danger::NoCertVerifier(
                provider::default_provider(),
            )));
    }

    Ok(config)
}

mod danger {
    use super::*;
    use rustls::{
        client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider},
        pki_types::UnixTime,
        DigitallySignedStruct,
        SignatureScheme,
    };

    #[derive(Debug)]
    pub(super) struct NoCertVerifier(pub(super) CryptoProvider);

    impl ServerCertVerifier for NoCertVerifier {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp: &[u8],
            _now: UnixTime,
        ) -> std::result::Result<ServerCertVerified, TlsError> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> std::result::Result<HandshakeSignatureValid, TlsError> {
            verify_tls12_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }

        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> std::result::Result<HandshakeSignatureValid, TlsError> {
            verify_tls13_signature(
                message,
                cert,
                dss,
                &self.0.signature_verification_algorithms,
            )
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }
}
