use std::io::Error;

use rustls::RootCertStore;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

use crate::connection::TlsConnParams;
use crate::{Client, ConnectionAddr, ConnectionInfo, ErrorKind, RedisError, RedisResult};

/// Structure to hold mTLS client _certificate_ and _key_ binaries in PEM format
///
#[derive(Clone)]
pub struct ClientTlsConfig {
    /// client certificate byte stream in PEM format
    pub client_cert: Vec<u8>,
    /// client key byte stream in PEM format
    pub client_key: Vec<u8>,
}

/// Structure to hold TLS certificates
/// - `client_tls`: binaries of clientkey and certificate within a `ClientTlsConfig` structure if mTLS is used
/// - `root_cert`: binary CA certificate in PEM format if CA is not in local truststore
///
#[derive(Clone)]
pub struct TlsCertificates {
    /// 'ClientTlsConfig' containing client certificate and key if mTLS is to be used
    pub client_tls: Option<ClientTlsConfig>,
    /// root certificate byte stream in PEM format if the local truststore is *not* to be used
    pub root_cert: Option<Vec<u8>>,
    /// Overrides the hostname used for certificate verification without
    /// changing which address the client dials. Set this when the dial
    /// address is a local forwarding endpoint, such as an SSH tunnel, but
    /// the certificate was issued for the server's real hostname.
    pub verify_host: Option<String>,
}

pub(crate) fn inner_build_with_tls(
    mut connection_info: ConnectionInfo,
    certificates: &TlsCertificates,
) -> RedisResult<Client> {
    let tls_params = retrieve_tls_certificates(certificates)?;

    connection_info.addr = if let ConnectionAddr::TcpTls {
        host,
        port,
        insecure,
        ..
    } = connection_info.addr
    {
        ConnectionAddr::TcpTls {
            host,
            port,
            insecure,
            tls_params: Some(tls_params),
        }
    } else {
        return Err(RedisError::from((
            ErrorKind::InvalidClientConfig,
            "Constructing a TLS client requires a URL with the `rediss://` scheme",
        )));
    };

    Ok(Client { connection_info })
}

pub(crate) fn retrieve_tls_certificates(
    certificates: &TlsCertificates,
) -> RedisResult<TlsConnParams> {
    let TlsCertificates {
        client_tls,
        root_cert,
        verify_host,
    } = certificates;

    let client_tls_params = if let Some(ClientTlsConfig {
        client_cert,
        client_key,
    }) = client_tls
    {
        let client_cert_chain = CertificateDer::pem_slice_iter(client_cert)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|err| {
                Error::other(format!(
                    "Unable to parse client certificate chain PEM: {err}"
                ))
            })?;

        let client_key = PrivateKeyDer::from_pem_slice(client_key).map_err(|err| {
            Error::other(format!(
                "Unable to extract private key from PEM file: {err}"
            ))
        })?;

        Some(ClientTlsParams {
            client_cert_chain,
            client_key,
        })
    } else {
        None
    };

    let root_cert_store = if let Some(root_cert) = root_cert {
        let mut root_cert_store = RootCertStore::empty();
        for result in CertificateDer::pem_slice_iter(root_cert) {
            let cert = result.map_err(|err| {
                Error::other(format!("Unable to parse root certificate PEM: {err}"))
            })?;

            if root_cert_store.add(cert).is_err() {
                return Err(Error::other("Unable to parse TLS trust anchors").into());
            }
        }

        Some(root_cert_store)
    } else {
        None
    };

    Ok(TlsConnParams {
        client_tls_params,
        root_cert_store,
        #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
        danger_accept_invalid_hostnames: false,
        verify_host: verify_host.clone(),
    })
}

#[derive(Debug)]
pub struct ClientTlsParams {
    pub(crate) client_cert_chain: Vec<CertificateDer<'static>>,
    pub(crate) client_key: PrivateKeyDer<'static>,
}

/// [`PrivateKeyDer`] does not implement `Clone` so we need to implement it manually.
impl Clone for ClientTlsParams {
    fn clone(&self) -> Self {
        use PrivateKeyDer::*;
        Self {
            client_cert_chain: self.client_cert_chain.clone(),
            client_key: match &self.client_key {
                Pkcs1(key) => Pkcs1(key.secret_pkcs1_der().to_vec().into()),
                Pkcs8(key) => Pkcs8(key.secret_pkcs8_der().to_vec().into()),
                Sec1(key) => Sec1(key.secret_sec1_der().to_vec().into()),
                _ => unreachable!(),
            },
        }
    }
}
