use std::sync::Arc;

use rustls::ClientConfig;
use rustls::client::danger::ServerCertVerifier;
use rustls::crypto::aws_lc_rs;
use tablepro_core::{TlsConfig, TlsMode};

use crate::tls::pem_check::{read_certificates, read_identity};
use crate::tls::{TlsSetupError, UnverifiedServerCertVerifier};

pub fn build_client_config(tls: &TlsConfig) -> Result<Option<Arc<ClientConfig>>, TlsSetupError> {
    let provider = Arc::new(aws_lc_rs::default_provider());
    let verifier: Arc<dyn ServerCertVerifier> = match tls.mode {
        TlsMode::Disable => return Ok(None),
        TlsMode::Require => Arc::new(UnverifiedServerCertVerifier::new(Arc::clone(&provider))),
        TlsMode::VerifyFull => {
            let extra_roots = match &tls.ca_file {
                Some(path) => read_certificates(path)?,
                None => Vec::new(),
            };
            Arc::new(rustls_platform_verifier::Verifier::new_with_extra_roots(
                extra_roots,
                Arc::clone(&provider),
            )?)
        }
    };
    let builder = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(rustls::DEFAULT_VERSIONS)?
        .dangerous()
        .with_custom_certificate_verifier(verifier);
    let config = match &tls.client_identity {
        Some(identity) => {
            let (certificates, key) = read_identity(identity)?;
            builder.with_client_auth_cert(certificates, key)?
        }
        None => builder.with_no_client_auth(),
    };
    Ok(Some(Arc::new(config)))
}
