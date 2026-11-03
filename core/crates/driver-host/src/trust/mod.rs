// Whether the app may load a driver file. Windows checks the Authenticode signature and its signer; macOS and
// Linux have no check here yet, so they refuse every file (docs/decisions/0004-driver-plugin-abi.md).

#[cfg(windows)]
mod authenticode;

use std::fs::File;
use std::path::Path;

use crate::error::PluginError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    // A new file: its certificates are checked for revocation too, online when the cache has no answer.
    Install,
    // A file installed and checked before: no network, so a driver loads offline.
    Load,
}

pub trait Trust: Send + Sync {
    // `file` is the open file about to be loaded, held so that nothing replaces it between the check and the load.
    fn verify(&self, file: &File, path: &Path, purpose: Purpose) -> Result<(), PluginError>;
}

// Who may sign a driver: the signing certificate's subject, as Windows writes it with the most specific part first
// ("CN=TablePro, O=TablePro, C=VN", the form .NET's X509Certificate2.Subject shows), and the SHA-256 of the
// certificate that issued it, lowercase hex, which is the signer's own for a self-signed one. The subject alone
// is a name any trusted CA may put in a certificate; the issuer pins the CA that vouched for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signer {
    pub subject: String,
    pub issuer_sha256: String,
}

pub struct PlatformTrust {
    signers: Vec<Signer>,
}

impl PlatformTrust {
    pub fn new(signers: Vec<Signer>) -> Self {
        Self { signers }
    }
}

impl Trust for PlatformTrust {
    #[cfg(windows)]
    fn verify(&self, file: &File, path: &Path, purpose: Purpose) -> Result<(), PluginError> {
        authenticode::verify(file, path, &self.signers, purpose)
    }

    #[cfg(not(windows))]
    fn verify(&self, _file: &File, _path: &Path, _purpose: Purpose) -> Result<(), PluginError> {
        let _ = &self.signers;
        Err(PluginError::TrustUnavailable)
    }
}

// Open for the check and the load. On Windows others may only read it until it is closed.
pub fn open_for_load(path: &Path) -> Result<File, PluginError> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(windows_sys::Win32::Storage::FileSystem::FILE_SHARE_READ);
    }
    options
        .open(path)
        .map_err(|error| PluginError::io(&format!("could not open {}", path.display()), &error))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table_pro() -> Signer {
        Signer {
            subject: "CN=TablePro".to_owned(),
            issuer_sha256: "00".repeat(32),
        }
    }

    #[cfg(not(windows))]
    #[test]
    fn a_platform_with_no_check_refuses_every_file() {
        let file = tempfile::NamedTempFile::new().unwrap();

        let error = PlatformTrust::new(vec![table_pro()])
            .verify(file.as_file(), file.path(), Purpose::Install)
            .unwrap_err();

        assert_eq!(error.code(), "plugin.trust_unavailable");
    }

    #[cfg(windows)]
    #[test]
    fn an_unsigned_file_is_refused() {
        let folder = tempfile::tempdir().unwrap();
        let copy = folder.path().join("unsigned.dll");
        std::fs::copy(std::env::current_exe().unwrap(), &copy).unwrap();
        let file = open_for_load(&copy).unwrap();

        let error = PlatformTrust::new(vec![table_pro()])
            .verify(&file, &copy, Purpose::Install)
            .unwrap_err();

        assert_eq!(error.code(), "plugin.unsigned");
    }

    #[cfg(windows)]
    #[test]
    fn a_file_held_for_a_load_cannot_be_replaced() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("held.dll");
        std::fs::write(&path, b"held").unwrap();
        let _held = open_for_load(&path).unwrap();

        assert!(std::fs::write(&path, b"swapped").is_err());
        assert!(std::fs::remove_file(&path).is_err());
    }
}
