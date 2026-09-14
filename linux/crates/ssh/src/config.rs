use std::path::PathBuf;

use secrecy::SecretString;

use crate::SshDestination;

#[derive(Debug, Clone)]
pub struct SshConfig {
    pub destination: SshDestination,
    pub jump_hosts: Vec<SshDestination>,
    pub auth: SshAuth,
}

#[derive(Debug, Clone)]
pub enum SshAuth {
    Agent,
    PrivateKey {
        path: Option<PathBuf>,
        passphrase: Option<SecretString>,
    },
    Password {
        password: SecretString,
    },
    KeyboardInteractive,
}
