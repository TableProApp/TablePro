use std::sync::Arc;

use hyper_rustls::{FixedServerNameResolver, HttpsConnector};
use hyper_util::client::legacy::connect::HttpConnector;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};
use rustls_pki_types::{CertificateDer, ServerName, UnixTime, pem::PemObject};
use tablepro_core::{DriverError, TlsConfig};

/// Build the connector ClickHouse talks through. `service_host` is the
/// database's own hostname, which is what the certificate was issued for.
/// The dial address in the request URI can instead be an SSH tunnel's
/// `127.0.0.1`, so the TLS verifier is pinned to `service_host` rather than
/// left to derive a name from the URI it connects to. The shared TLS modes
/// are mapped onto rustls, which has no CA-only mode, so `VerifyCa` verifies
/// the hostname as well: stricter than requested and never weaker.
pub(crate) fn https_connector(
    config: &TlsConfig,
    service_host: &str,
) -> Result<HttpsConnector<HttpConnector>, DriverError> {
    let mut connector = HttpConnector::new();
    connector.enforce_http(false);
    Ok(hyper_rustls::HttpsConnectorBuilder::new()
        .with_tls_config(client_config(config)?)
        .https_or_http()
        .with_server_name_resolver(FixedServerNameResolver::new(server_name(service_host)?))
        .enable_http1()
        .wrap_connector(connector))
}

fn server_name(service_host: &str) -> Result<ServerName<'static>, DriverError> {
    ServerName::try_from(service_host.to_string())
        .map_err(|error| DriverError::Tls(format!("invalid TLS server name \"{service_host}\": {error}")))
}

fn client_config(config: &TlsConfig) -> Result<ClientConfig, DriverError> {
    // Another driver in this workspace pulls in a second rustls provider, so
    // the process-wide default is ambiguous and has to be named here.
    let builder = ClientConfig::builder_with_provider(Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|error| DriverError::Tls(format!("cannot configure TLS: {error}")))?;
    if !config.mode.verifies_cert() {
        return Ok(builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAnyServer))
            .with_no_client_auth());
    }
    Ok(builder.with_root_certificates(roots(config)?).with_no_client_auth())
}

fn roots(config: &TlsConfig) -> Result<RootCertStore, DriverError> {
    let Some(path) = &config.root_cert else {
        return Ok(system_or_bundled_roots(rustls_native_certs::load_native_certs().certs));
    };
    let mut store = RootCertStore::empty();
    let certificates = CertificateDer::pem_file_iter(path).map_err(|error| {
        DriverError::Tls(format!(
            "cannot read the certificate authority at {}: {error}",
            path.display()
        ))
    })?;
    for certificate in certificates {
        let certificate = certificate.map_err(|error| {
            DriverError::Tls(format!(
                "cannot parse the certificate authority at {}: {error}",
                path.display()
            ))
        })?;
        store
            .add(certificate)
            .map_err(|error| DriverError::Tls(format!("cannot trust the certificate authority: {error}")))?;
    }
    if store.is_empty() {
        return Err(DriverError::Tls(format!("no certificate found in {}", path.display())));
    }
    Ok(store)
}

fn system_or_bundled_roots(system: Vec<CertificateDer<'static>>) -> RootCertStore {
    let mut store = RootCertStore::empty();
    let (added, _ignored) = store.add_parsable_certificates(system);
    if added == 0 {
        store.roots = webpki_roots::TLS_SERVER_ROOTS.to_vec();
    }
    store
}

/// Used only when the selected mode encrypts without verifying, which is what
/// `Prefer` and `Require` mean across every driver in this workspace.
#[derive(Debug)]
struct AcceptAnyServer;

impl ServerCertVerifier for AcceptAnyServer {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::aws_lc_rs::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use hyper_rustls::ResolveServerName;

    use super::*;

    #[test]
    fn server_name_resolves_to_the_service_host_not_the_tunnel_address() {
        let resolver = FixedServerNameResolver::new(server_name("db.internal.example").expect("valid hostname"));
        let tunnel_uri: http::Uri = "https://127.0.0.1:9440".parse().expect("valid uri");

        let resolved = resolver.resolve(&tunnel_uri).expect("resolves a name");

        assert_eq!(
            resolved,
            ServerName::try_from("db.internal.example".to_string()).expect("valid hostname")
        );
    }

    #[test]
    fn server_name_rejects_an_empty_hostname() {
        assert!(server_name("").is_err());
    }

    const TEST_CA: &str = "-----BEGIN CERTIFICATE-----\n\
MIIBiTCCAS+gAwIBAgIUKe+/bunQMNOqUMPEXr8ueW4t/7EwCgYIKoZIzj0EAwIw\n\
GTEXMBUGA1UEAwwOYm9va2llLXRlc3QtY2EwIBcNMjYxMDIwMjMyNjQ2WhgPMjEy\n\
NjA5MjYyMzI2NDZaMBkxFzAVBgNVBAMMDmJvb2tpZS10ZXN0LWNhMFkwEwYHKoZI\n\
zj0CAQYIKoZIzj0DAQcDQgAEPBCdwYlAFqIB019uiMUz/1SlT2JhTvPy1cTd9jTk\n\
4yJkMa80o9PYJwuR5eXMI6QfCNxNCb/6TwTtGWIy/SFbaKNTMFEwHQYDVR0OBBYE\n\
FHXsWCxCFp8MB/D3vSMIm0yCtMmoMB8GA1UdIwQYMBaAFHXsWCxCFp8MB/D3vSMI\n\
m0yCtMmoMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgCTUS8SzP\n\
lQ/PlAPhU8FNTeam5qHsq6n80rHvvvbi9BQCIQD/QUETsrc8D6E/duRtQizvyRHD\n\
Iwyyvl081qMRweKHRA==\n\
-----END CERTIFICATE-----\n";

    #[test]
    fn the_system_trust_store_replaces_the_bundled_roots_when_it_has_certificates() {
        let system = CertificateDer::pem_slice_iter(TEST_CA.as_bytes())
            .collect::<Result<Vec<_>, _>>()
            .expect("test authority parses");

        let store = system_or_bundled_roots(system);

        assert_eq!(store.roots.len(), 1);
    }

    #[test]
    fn an_empty_system_store_falls_back_to_the_bundled_roots() {
        let store = system_or_bundled_roots(Vec::new());

        assert_eq!(store.roots.len(), webpki_roots::TLS_SERVER_ROOTS.len());
    }
}
