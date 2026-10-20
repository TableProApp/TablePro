/// A client key algorithm `ssh-keygen` generates for a test.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SshKeyType {
    Ed25519,
    /// 3072 bits, `ssh-keygen`'s default size.
    Rsa,
    EcdsaP256,
}

impl SshKeyType {
    pub const ALL: [Self; 3] = [Self::Ed25519, Self::Rsa, Self::EcdsaP256];

    pub(crate) fn keygen_arguments(self) -> &'static [&'static str] {
        match self {
            Self::Ed25519 => &["-t", "ed25519"],
            Self::Rsa => &["-t", "rsa", "-b", "3072"],
            Self::EcdsaP256 => &["-t", "ecdsa", "-b", "256"],
        }
    }

    pub(crate) fn file_name(self) -> &'static str {
        match self {
            Self::Ed25519 => "id_ed25519",
            Self::Rsa => "id_rsa",
            Self::EcdsaP256 => "id_ecdsa",
        }
    }

    /// The key type an OpenSSH public key line starts with.
    pub fn public_key_type(self) -> &'static str {
        match self {
            Self::Ed25519 => "ssh-ed25519",
            Self::Rsa => "ssh-rsa",
            Self::EcdsaP256 => "ecdsa-sha2-nistp256",
        }
    }
}
