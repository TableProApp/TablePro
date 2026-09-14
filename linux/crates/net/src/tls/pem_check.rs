use std::path::Path;

use rustls::RootCertStore;
use rustls_pki_types::pem::{self, PemObject};
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use tablepro_core::{CertificateFileProblem, ClientIdentity, ConfigError, TlsConfig};

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
    load_certificates(path).map_err(|problem| ConfigError::CaFile {
        path: path.to_owned(),
        problem,
    })
}

pub(crate) fn read_identity(
    identity: &ClientIdentity,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), ConfigError> {
    let identity_problem = |path: &Path, problem| ConfigError::ClientIdentityFile {
        path: path.to_owned(),
        problem,
    };
    let certificates =
        load_certificates(&identity.certificate).map_err(|problem| identity_problem(&identity.certificate, problem))?;
    let key = PrivateKeyDer::from_pem_file(&identity.key).map_err(|error| {
        let problem = match error {
            pem::Error::Io(error) => CertificateFileProblem::Unreadable {
                detail: error.to_string(),
            },
            pem::Error::NoItemsFound => CertificateFileProblem::NoPrivateKey,
            other => CertificateFileProblem::InvalidPrivateKey {
                detail: other.to_string(),
            },
        };
        identity_problem(&identity.key, problem)
    })?;
    Ok((certificates, key))
}

fn load_certificates(path: &Path) -> Result<Vec<CertificateDer<'static>>, CertificateFileProblem> {
    let certificates = CertificateDer::pem_file_iter(path)
        .map_err(certificate_problem)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(certificate_problem)?;
    if certificates.is_empty() {
        return Err(CertificateFileProblem::NoCertificates);
    }
    let mut scratch = RootCertStore::empty();
    for certificate in &certificates {
        scratch
            .add(certificate.clone())
            .map_err(|error| CertificateFileProblem::InvalidCertificate {
                detail: error.to_string(),
            })?;
    }
    Ok(certificates)
}

fn certificate_problem(error: pem::Error) -> CertificateFileProblem {
    match error {
        pem::Error::Io(error) => CertificateFileProblem::Unreadable {
            detail: error.to_string(),
        },
        pem::Error::NoItemsFound => CertificateFileProblem::NoCertificates,
        other => CertificateFileProblem::InvalidCertificate {
            detail: other.to_string(),
        },
    }
}
