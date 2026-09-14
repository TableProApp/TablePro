use crate::SshKeyPair;

#[derive(Debug)]
pub enum SshAuthVariant {
    Password,
    PublicKey(SshKeyPair),
    KeyboardInteractive,
    HostCertificate,
}

impl SshAuthVariant {
    pub fn password_access(&self) -> bool {
        !matches!(self, Self::PublicKey(_))
    }
}
