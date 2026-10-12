use rcgen::{PKCS_ECDSA_P384_SHA384, PKCS_ED25519, PKCS_RSA_SHA256, SignatureAlgorithm};

/// The key type a whole test PKI is built from.
///
/// It applies to the CAs as well as the leaves, because a certificate's
/// signature algorithm is its issuer's, and PostgreSQL channel binding
/// hashes the server certificate by that signature algorithm.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PkiAlgorithm {
    #[default]
    RsaSha256,
    EcdsaP384Sha384,
    Ed25519,
}

impl PkiAlgorithm {
    pub const ALL: [Self; 3] = [Self::RsaSha256, Self::EcdsaP384Sha384, Self::Ed25519];

    pub(crate) fn signature_algorithm(self) -> &'static SignatureAlgorithm {
        match self {
            Self::RsaSha256 => &PKCS_RSA_SHA256,
            Self::EcdsaP384Sha384 => &PKCS_ECDSA_P384_SHA384,
            Self::Ed25519 => &PKCS_ED25519,
        }
    }

    /// Only an RSA key can encrypt, so key encipherment is a usage an
    /// ECDSA or Ed25519 certificate must not claim.
    pub(crate) fn enciphers_keys(self) -> bool {
        matches!(self, Self::RsaSha256)
    }
}
