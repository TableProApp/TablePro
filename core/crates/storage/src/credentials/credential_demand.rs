use tablepro_core::credentials::SecretKind;

/// What the caller wants beyond the stored secrets.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CredentialDemand {
    /// The secret of this kind was just refused by the server, so the
    /// stored one is skipped and the user is asked again.
    pub reenter: Option<SecretKind>,
}

impl CredentialDemand {
    pub fn reenter(kind: SecretKind) -> Self {
        Self { reenter: Some(kind) }
    }
}
