use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose, PKCS_RSA_SHA256,
};
use tempfile::TempDir;

use crate::{FixtureError, PkiFile};

pub struct TestPki {
    dir: TempDir,
}

impl TestPki {
    pub const SERVER_NAMES: [&'static str; 2] = ["localhost", "db.tablepro.test"];
    pub const CLIENT_COMMON_NAME: &'static str = "tablepro_client";

    pub fn generate() -> Result<Self, FixtureError> {
        let (ca_pem, ca) = certificate_authority("TablePro Test CA")?;
        let (unrelated_ca_pem, _) = certificate_authority("Unrelated Test CA")?;

        let server_key = KeyPair::generate_for(&PKCS_RSA_SHA256)?;
        let mut server = CertificateParams::new(Self::SERVER_NAMES.map(str::to_owned).to_vec())?;
        server.distinguished_name = common_name(Self::SERVER_NAMES[0]);
        server.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyEncipherment];
        server.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let server_certificate = server.signed_by(&server_key, &ca)?;

        let client_key = KeyPair::generate_for(&PKCS_RSA_SHA256)?;
        let mut client = CertificateParams::new(Vec::<String>::new())?;
        client.distinguished_name = common_name(Self::CLIENT_COMMON_NAME);
        client.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyEncipherment];
        client.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
        let client_certificate = client.signed_by(&client_key, &ca)?;

        let pki = Self {
            dir: tempfile::tempdir()?,
        };
        pki.write(PkiFile::Ca, ca_pem.as_bytes())?;
        pki.write(PkiFile::UnrelatedCa, unrelated_ca_pem.as_bytes())?;
        pki.write(PkiFile::ServerCertificate, server_certificate.pem().as_bytes())?;
        pki.write(PkiFile::ServerKey, server_key.serialize_pem().as_bytes())?;
        pki.write(PkiFile::ClientCertificate, client_certificate.pem().as_bytes())?;
        pki.write(PkiFile::ClientKey, client_key.serialize_pem().as_bytes())?;
        Ok(pki)
    }

    pub fn dir(&self) -> &Path {
        self.dir.path()
    }

    pub fn path(&self, file: PkiFile) -> PathBuf {
        self.dir.path().join(file.file_name())
    }

    pub fn read(&self, file: PkiFile) -> Result<Vec<u8>, FixtureError> {
        Ok(std::fs::read(self.path(file))?)
    }

    fn write(&self, file: PkiFile, contents: &[u8]) -> Result<(), FixtureError> {
        let mode = if file.is_private_key() { 0o600 } else { 0o644 };
        let mut handle = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(self.path(file))?;
        handle.write_all(contents)?;
        Ok(())
    }
}

fn certificate_authority(name: &str) -> Result<(String, Issuer<'static, KeyPair>), FixtureError> {
    let key = KeyPair::generate_for(&PKCS_RSA_SHA256)?;
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.distinguished_name = common_name(name);
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
        KeyUsagePurpose::DigitalSignature,
    ];
    let certificate = params.self_signed(&key)?;
    Ok((certificate.pem(), Issuer::new(params, key)))
}

fn common_name(name: &str) -> DistinguishedName {
    let mut distinguished_name = DistinguishedName::new();
    distinguished_name.push(DnType::CommonName, name);
    distinguished_name
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    use rustls::client::WebPkiServerVerifier;
    use rustls::client::danger::ServerCertVerifier;
    use rustls::pki_types::pem::PemObject;
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{CertificateError, RootCertStore};

    use super::*;

    fn verify(pki: &TestPki, ca: PkiFile, server_name: &str) -> Result<(), rustls::Error> {
        let mut roots = RootCertStore::empty();
        for certificate in CertificateDer::pem_file_iter(pki.path(ca)).unwrap() {
            roots.add(certificate.unwrap()).unwrap();
        }
        let verifier = WebPkiServerVerifier::builder_with_provider(
            Arc::new(roots),
            Arc::new(rustls::crypto::aws_lc_rs::default_provider()),
        )
        .build()
        .unwrap();
        let server_certificate = CertificateDer::from_pem_file(pki.path(PkiFile::ServerCertificate)).unwrap();
        verifier
            .verify_server_cert(
                &server_certificate,
                &[],
                &ServerName::try_from(server_name).unwrap(),
                &[],
                UnixTime::now(),
            )
            .map(|_| ())
    }

    #[test]
    fn server_certificate_verifies_against_the_issuing_ca() {
        let pki = TestPki::generate().unwrap();
        for name in TestPki::SERVER_NAMES {
            verify(&pki, PkiFile::Ca, name).unwrap();
        }
    }

    #[test]
    fn server_certificate_rejects_an_ip_address_name() {
        let pki = TestPki::generate().unwrap();
        let error = verify(&pki, PkiFile::Ca, "127.0.0.1").unwrap_err();
        assert!(matches!(
            error,
            rustls::Error::InvalidCertificate(
                CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. }
            )
        ));
    }

    #[test]
    fn server_certificate_fails_against_unrelated_ca() {
        let pki = TestPki::generate().unwrap();
        let error = verify(&pki, PkiFile::UnrelatedCa, "localhost").unwrap_err();
        assert!(matches!(
            error,
            rustls::Error::InvalidCertificate(CertificateError::UnknownIssuer)
        ));
    }

    #[test]
    fn client_certificate_common_name_is_tablepro_client() {
        let pki = TestPki::generate().unwrap();
        let certificate = CertificateDer::from_pem_file(pki.path(PkiFile::ClientCertificate)).unwrap();
        let name = TestPki::CLIENT_COMMON_NAME.as_bytes();
        let mut attribute = vec![0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, name.len() as u8];
        attribute.extend_from_slice(name);

        assert!(certificate.windows(attribute.len()).any(|window| window == attribute));
    }

    #[test]
    fn ca_file_holds_exactly_one_certificate() {
        let pki = TestPki::generate().unwrap();
        for file in [PkiFile::Ca, PkiFile::UnrelatedCa] {
            let certificates: Vec<_> = CertificateDer::pem_file_iter(pki.path(file)).unwrap().collect();
            assert_eq!(certificates.len(), 1, "{}", file.file_name());
        }
    }

    #[test]
    fn private_keys_are_written_0600() {
        let pki = TestPki::generate().unwrap();
        for file in PkiFile::ALL {
            let mode = std::fs::metadata(pki.path(file)).unwrap().permissions().mode() & 0o777;
            let expected = if file.is_private_key() { 0o600 } else { 0o644 };
            assert_eq!(mode, expected, "{}", file.file_name());
        }
    }
}
