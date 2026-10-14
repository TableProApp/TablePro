//! What the machine offers for SSH logins.

use std::path::PathBuf;

/// What the machine offers for SSH logins, read each time the connect
/// dialog opens so a test can say what it has instead.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SshEnvironment {
    pub agent: bool,
    pub default_key: Option<PathBuf>,
}

impl SshEnvironment {
    /// Looking for a key file reads the disk, so this runs on the
    /// blocking pool, never on the GTK thread.
    pub fn detect_blocking() -> Self {
        let agent = std::env::var_os("SSH_AUTH_SOCK").is_some_and(|socket| !socket.is_empty());
        let ssh_dir = glib::home_dir().join(".ssh");
        let default_key = ["id_ed25519", "id_ecdsa", "id_rsa"]
            .into_iter()
            .map(|candidate| ssh_dir.join(candidate))
            .find(|path| path.exists());
        Self { agent, default_key }
    }
}
