use crate::SshKeyPair;

#[derive(Debug)]
pub enum SshAuthVariant {
    Password,
    PublicKey(SshKeyPair),
    /// TrustedUserCAKeys names this key, so only a certificate it signed
    /// logs in.
    UserCertificateAuthority(SshKeyPair),
    KeyboardInteractive,
    HostCertificate,
}

impl SshAuthVariant {
    pub fn password_access(&self) -> bool {
        !matches!(self, Self::PublicKey(_) | Self::UserCertificateAuthority(_))
    }
}
