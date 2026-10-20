use crate::SshKeyPair;

#[derive(Debug)]
pub enum SshAuthVariant {
    Password,
    PublicKey(SshKeyPair),
    /// Several keys in authorized_keys, so one server takes a matrix of
    /// client keys.
    PublicKeys(Vec<SshKeyPair>),
    /// TrustedUserCAKeys names this key, so only a certificate it signed
    /// logs in.
    UserCertificateAuthority(SshKeyPair),
    KeyboardInteractive,
    HostCertificate,
}

impl SshAuthVariant {
    pub fn password_access(&self) -> bool {
        !matches!(
            self,
            Self::PublicKey(_) | Self::PublicKeys(_) | Self::UserCertificateAuthority(_)
        )
    }

    /// The authorized_keys lines the server starts with.
    pub fn authorized_keys(&self) -> Vec<&str> {
        match self {
            Self::PublicKey(key) => vec![key.public_key()],
            Self::PublicKeys(keys) => keys.iter().map(SshKeyPair::public_key).collect(),
            Self::UserCertificateAuthority(_) | Self::Password | Self::KeyboardInteractive | Self::HostCertificate => {
                Vec::new()
            }
        }
    }
}
