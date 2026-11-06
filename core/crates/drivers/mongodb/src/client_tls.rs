use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use mongodb::options::{Tls, TlsOptions};
use tablepro_core::{DriverError, TlsConfig, TlsMode};
use tempfile::TempDir;

/// The TLS the client library sets up itself, where it dials the servers:
/// over a direct route and to the servers a DNS seed list names.
///
/// The library fills its trust from webpki-roots unless it is given a CA
/// file, and then trusts that file alone. So a verified connection always
/// gets one: the system store with the user's CA file after it, the roots
/// every other engine checks a certificate against. The library takes a
/// client certificate the same way, as one file holding it and its key.
/// Both are written only while a client is built, which is when the
/// library reads them, into a directory only the user can open.
#[derive(Clone)]
pub(crate) struct ClientTls {
    mode: TlsMode,
    roots: Option<Vec<u8>>,
    identity: Option<Vec<u8>>,
}

impl std::fmt::Debug for ClientTls {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientTls")
            .field("mode", &self.mode)
            .field("roots_bytes", &self.roots.as_ref().map(Vec::len))
            .field("identity", &self.identity.is_some())
            .finish()
    }
}

impl ClientTls {
    /// Reads the system store and the files the connection names, so it
    /// runs off the runtime.
    pub(crate) fn new(tls: &TlsConfig) -> Result<Self, DriverError> {
        let roots = match tls.mode {
            TlsMode::VerifyFull => Some(tablepro_net::tls::ca_bundle_pem(tls).map_err(crate::endpoint::setup_error)?),
            TlsMode::Disable | TlsMode::Require => None,
            // TLS is a property of the port, so there is nothing to prefer.
            TlsMode::Prefer | TlsMode::Strict => {
                return Err(DriverError::Config(tablepro_core::ConfigError::UnsupportedTlsMode));
            }
        };
        let identity = match tablepro_net::tls::client_identity_pem(tls).map_err(crate::endpoint::setup_error)? {
            Some(pem) => {
                let mut combined = pem.certificate;
                if !combined.ends_with(b"\n") {
                    combined.push(b'\n');
                }
                combined.extend_from_slice(&pem.key);
                Some(combined)
            }
            None => None,
        };
        Ok(Self {
            mode: tls.mode,
            roots,
            identity,
        })
    }

    pub(crate) fn enabled(&self) -> bool {
        self.mode != TlsMode::Disable
    }

    /// The library's TLS option, with the files it reads written into
    /// `dir`, which the caller removes once the client is built.
    pub(crate) fn option(&self, dir: &Path) -> io::Result<Tls> {
        if self.mode == TlsMode::Disable {
            return Ok(Tls::Disabled);
        }
        let mut options = TlsOptions::default();
        match &self.roots {
            Some(roots) => options.ca_file_path = Some(write_private(dir, "ca.pem", roots)?),
            None => options.allow_invalid_certificates = Some(true),
        }
        if let Some(identity) = &self.identity {
            options.cert_key_file_path = Some(write_private(dir, "client.pem", identity)?);
        }
        Ok(Tls::Enabled(options))
    }
}

pub(crate) fn private_dir() -> io::Result<TempDir> {
    tablepro_net::private_dir("tablepro-mongodb-")
}

fn write_private(dir: &Path, name: &str, contents: &[u8]) -> io::Result<PathBuf> {
    let path = dir.join(name);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file: File = options.open(&path)?;
    file.write_all(contents)?;
    file.sync_all()?;
    Ok(path)
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn a_verified_connection_always_names_a_ca_file_and_require_checks_nothing() {
        let dir = private_dir().expect("a directory");
        let verified = ClientTls {
            mode: TlsMode::VerifyFull,
            roots: Some(b"-----BEGIN CERTIFICATE-----\n".to_vec()),
            identity: Some(b"cert\nkey\n".to_vec()),
        };

        let Tls::Enabled(options) = verified.option(dir.path()).expect("the files") else {
            panic!("TLS was off");
        };

        let ca = options.ca_file_path.expect("a CA file");
        assert_eq!(
            std::fs::metadata(&ca).expect("the CA file").permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(dir.path())
                .expect("the directory")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert!(options.cert_key_file_path.is_some());
        assert_eq!(options.allow_invalid_certificates, None);

        let required = ClientTls {
            mode: TlsMode::Require,
            roots: None,
            identity: None,
        };
        let Tls::Enabled(options) = required.option(dir.path()).expect("no files") else {
            panic!("TLS was off");
        };
        assert_eq!(options.allow_invalid_certificates, Some(true));
        assert_eq!(options.ca_file_path, None);
        let off = ClientTls {
            mode: TlsMode::Disable,
            roots: None,
            identity: None,
        };
        assert!(matches!(off.option(dir.path()), Ok(Tls::Disabled)));
    }
}
