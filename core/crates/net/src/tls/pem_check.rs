use std::fs::File;
use std::io::Read;
use std::path::Path;

use rustls::RootCertStore;
use rustls_pki_types::pem::{self, PemObject};
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use tablepro_core::{CertificateFileProblem, ClientIdentity, ConfigError, TlsConfig};

/// The most a CA, certificate or key file may hold. A bundle of every
/// root a distribution trusts is about 220 KiB.
pub const MAX_PEM_FILE_BYTES: usize = 1024 * 1024;

/// A client certificate and key as read, both as the PEM text and as
/// what rustls takes, so each file is read once.
pub(crate) struct IdentityFiles {
    pub certificate_pem: Vec<u8>,
    pub key_pem: Vec<u8>,
    pub certificates: Vec<CertificateDer<'static>>,
    pub key: PrivateKeyDer<'static>,
}

pub fn check_pem_files(tls: &TlsConfig) -> Result<(), ConfigError> {
    if let Some(ca_file) = &tls.ca_file {
        read_certificates(ca_file)?;
    }
    if let Some(identity) = &tls.client_identity {
        read_identity(identity)?;
    }
    Ok(())
}

pub(crate) fn read_certificates(path: &Path) -> Result<Vec<CertificateDer<'static>>, ConfigError> {
    read_pem_file(path)
        .and_then(|bytes| parse_certificates(&bytes))
        .map_err(|problem| ConfigError::CaFile {
            path: path.to_owned(),
            problem,
        })
}

pub(crate) fn read_identity(identity: &ClientIdentity) -> Result<IdentityFiles, ConfigError> {
    let identity_problem = |path: &Path, problem| ConfigError::ClientIdentityFile {
        path: path.to_owned(),
        problem,
    };
    let certificate_pem =
        read_pem_file(&identity.certificate).map_err(|problem| identity_problem(&identity.certificate, problem))?;
    let certificates =
        parse_certificates(&certificate_pem).map_err(|problem| identity_problem(&identity.certificate, problem))?;
    let key_pem = read_pem_file(&identity.key).map_err(|problem| identity_problem(&identity.key, problem))?;
    let key = PrivateKeyDer::from_pem_slice(&key_pem).map_err(|error| {
        let problem = match error {
            pem::Error::NoItemsFound => CertificateFileProblem::NoPrivateKey,
            other => {
                tracing::debug!(error = %other, "the private key file is not valid");
                CertificateFileProblem::InvalidPrivateKey
            }
        };
        identity_problem(&identity.key, problem)
    })?;
    Ok(IdentityFiles {
        certificate_pem,
        key_pem,
        certificates,
        key,
    })
}

/// The whole file, read only when it is a regular file of at most
/// `MAX_PEM_FILE_BYTES`. Opening a FIFO waits for a writer that may
/// never come, and a device such as `/dev/zero` has no end, so either
/// would hold the connect forever or fill memory.
fn read_pem_file(path: &Path) -> Result<Vec<u8>, CertificateFileProblem> {
    let unreadable = |error: std::io::Error| CertificateFileProblem::Unreadable { kind: error.kind() };
    if !std::fs::metadata(path).map_err(unreadable)?.is_file() {
        return Err(CertificateFileProblem::NotRegularFile);
    }
    let file = File::open(path).map_err(unreadable)?;
    // What was opened may not be what was looked at a moment before.
    if !file.metadata().map_err(unreadable)?.is_file() {
        return Err(CertificateFileProblem::NotRegularFile);
    }
    let mut bytes = Vec::new();
    file.take(MAX_PEM_FILE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(unreadable)?;
    if bytes.len() > MAX_PEM_FILE_BYTES {
        return Err(CertificateFileProblem::TooLarge {
            limit_bytes: MAX_PEM_FILE_BYTES,
        });
    }
    Ok(bytes)
}

fn parse_certificates(bytes: &[u8]) -> Result<Vec<CertificateDer<'static>>, CertificateFileProblem> {
    let certificates = CertificateDer::pem_slice_iter(bytes)
        .collect::<Result<Vec<_>, _>>()
        .map_err(certificate_problem)?;
    if certificates.is_empty() {
        return Err(CertificateFileProblem::NoCertificates);
    }
    let mut scratch = RootCertStore::empty();
    for certificate in &certificates {
        scratch.add(certificate.clone()).map_err(|error| {
            tracing::debug!(%error, "a certificate in the file is not valid");
            CertificateFileProblem::InvalidCertificate
        })?;
    }
    Ok(certificates)
}

fn certificate_problem(error: pem::Error) -> CertificateFileProblem {
    match error {
        pem::Error::NoItemsFound => CertificateFileProblem::NoCertificates,
        other => {
            tracing::debug!(error = %other, "the certificate file is not valid PEM");
            CertificateFileProblem::InvalidCertificate
        }
    }
}
