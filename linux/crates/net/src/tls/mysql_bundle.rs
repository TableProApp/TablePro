use pem_rfc7468::LineEnding;
use rustls::RootCertStore;
use tablepro_core::{CertificateFileProblem, ConfigError, TlsConfig};

use crate::tls::TlsSetupError;
use crate::tls::pem_check::{read_certificates, read_identity};

pub fn mysql_ca_bundle_pem(tls: &TlsConfig) -> Result<Vec<u8>, TlsSetupError> {
    let native = rustls_native_certs::load_native_certs();
    if !native.errors.is_empty() {
        tracing::warn!(
            errors = native.errors.len(),
            "some system CA certificates could not be loaded"
        );
    }
    let mut scratch = RootCertStore::empty();
    let mut accepted = Vec::with_capacity(native.certs.len());
    for certificate in native.certs {
        if scratch.add(certificate.clone()).is_ok() {
            accepted.push(certificate);
        }
    }
    if let Some(ca_file) = &tls.ca_file {
        accepted.extend(read_certificates(ca_file)?);
    }
    let mut bundle = String::new();
    for certificate in &accepted {
        let pem = pem_rfc7468::encode_string("CERTIFICATE", LineEnding::LF, certificate.as_ref())
            .map_err(TlsSetupError::PemEncoding)?;
        bundle.push_str(&pem);
    }
    Ok(bundle.into_bytes())
}

pub struct ClientIdentityPem {
    pub certificate: Vec<u8>,
    pub key: Vec<u8>,
}

impl std::fmt::Debug for ClientIdentityPem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientIdentityPem")
            .field("certificate_bytes", &self.certificate.len())
            .field("key_bytes", &self.key.len())
            .finish()
    }
}

pub fn client_identity_pem(tls: &TlsConfig) -> Result<Option<ClientIdentityPem>, TlsSetupError> {
    let Some(identity) = &tls.client_identity else {
        return Ok(None);
    };
    read_identity(identity)?;
    let read = |path: &std::path::Path| {
        std::fs::read(path).map_err(|error| ConfigError::ClientIdentityFile {
            path: path.to_owned(),
            problem: CertificateFileProblem::Unreadable {
                detail: error.to_string(),
            },
        })
    };
    Ok(Some(ClientIdentityPem {
        certificate: read(&identity.certificate)?,
        key: read(&identity.key)?,
    }))
}
