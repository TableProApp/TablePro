use std::path::PathBuf;
use std::time::Duration;

use secrecy::SecretString;

use super::SshDestination;

#[derive(Debug, Clone)]
pub struct OpenSshConfig {
    pub destination: SshDestination,
    pub jump_hosts: Vec<SshDestination>,
    pub auth: OpenSshAuth,
}

#[derive(Debug, Clone)]
pub enum OpenSshAuth {
    Agent,
    PrivateKey {
        path: Option<PathBuf>,
        passphrase: Option<SecretString>,
    },
    Password {
        password: SecretString,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenSshTimeouts {
    pub connect: Duration,
    pub handshake: Duration,
    pub channel_open: Duration,
    pub keepalive_interval: Duration,
    pub keepalive_max: u32,
    pub grace: Duration,
}

impl Default for OpenSshTimeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(10),
            handshake: Duration::from_secs(30),
            channel_open: Duration::from_secs(10),
            keepalive_interval: Duration::from_secs(15),
            keepalive_max: 3,
            grace: Duration::from_secs(2),
        }
    }
}
