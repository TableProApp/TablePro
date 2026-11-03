use std::path::Path;

use tablepro_core::TlsMode;

use crate::{ForeignAppDirs, ForeignConnection, ForeignSslMode};

// What the review tells the user about a row. Paths are as the other app wrote them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowNote {
    UnsupportedEngine { engine: String },
    SshKeyMissing { path: String },
    JumpHostKeyMissing { path: String },
    CaCertificateMissing { path: String },
    ClientCertificateMissing { path: String },
    ClientKeyMissing { path: String },
    TlsModeChanged { from: ForeignSslMode, to: TlsMode },
    // The app saved TLS settings the importer cannot read, so the row starts unchecked.
    TlsSettingsNotRead,
    // The engine has no TLS, so the connection opens in the clear.
    TlsNotKept { from: ForeignSslMode },
    CaFileNotKept { path: String, reason: TlsFileReason },
    ClientIdentityNotKept { reason: TlsFileReason },
    // A file engine opens a local file, never through a tunnel.
    SshNotKept,
    SshKeyNotKept { path: String },
    // The host or user cannot be written as one hop of the jump list.
    JumpHostNotKept { host: String },
    // A hop signs in through the SSH agent or the SSH config.
    JumpHostPasswordNotKept { host: String },
    JumpHostKeyNotKept { host: String, path: String },
    FieldsNotKept { fields: Vec<String> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TlsFileReason {
    EngineLacks,
    // A CA file needs Verify Full, and a client identity needs TLS on.
    ModeLacks,
    RelativePath,
    // A certificate without its key, or a key without its certificate.
    Incomplete,
}

pub(super) fn missing_files(
    settings: &ForeignConnection,
    dirs: &ForeignAppDirs,
    file_exists: &dyn Fn(&Path) -> bool,
) -> Vec<RowNote> {
    let missing = |path: &str| {
        let expanded = dirs.expand_home(path);
        !expanded.as_os_str().is_empty() && !file_exists(&expanded)
    };
    let mut notes = Vec::new();
    if let Some(ssh) = &settings.ssh {
        if missing(&ssh.private_key_path) {
            notes.push(RowNote::SshKeyMissing {
                path: ssh.private_key_path.clone(),
            });
        }
        for jump in &ssh.jump_hosts {
            if missing(&jump.private_key_path) {
                notes.push(RowNote::JumpHostKeyMissing {
                    path: jump.private_key_path.clone(),
                });
            }
        }
    }
    if let Some(ssl) = &settings.ssl {
        let missing_path = |path: &Option<String>| path.clone().filter(|path| missing(path));
        if let Some(path) = missing_path(&ssl.ca_certificate_path) {
            notes.push(RowNote::CaCertificateMissing { path });
        }
        if let Some(path) = missing_path(&ssl.client_certificate_path) {
            notes.push(RowNote::ClientCertificateMissing { path });
        }
        if let Some(path) = missing_path(&ssl.client_key_path) {
            notes.push(RowNote::ClientKeyMissing { path });
        }
    }
    notes
}
