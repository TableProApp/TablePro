// The codes are ADR 0056's Errors table as 0059 and 0064 amend it; a server's codes are 0051's and
// never appear here.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeysError {
    #[error("suite {found:?} is not tp1")]
    Suite { found: String },
    #[error("bad encoding: {what}")]
    Encoding { what: &'static str },
    #[error("recovery key text has the wrong length, a bad symbol or a bad checksum")]
    RecoveryKey,
    #[error("a signature does not verify")]
    Signature,
    #[error("an X25519 shared secret is all zero")]
    PublicKey,
    #[error("a ciphertext does not open")]
    Open,
    #[error("keys do not match their certificate: {what}")]
    Mismatch { what: &'static str },
    #[error("a key does not match its version's kid")]
    Kid,
    #[error("a ring entry is not the version below its own")]
    Ring,
    #[error("version {offered} is below {held}")]
    Stale { held: u32, offered: u32 },
    #[error("version {offered} skips past {held}")]
    Step { held: u32, offered: u32 },
    #[error("a certificate under an identity key seen replaced is offered as the newest")]
    RetiredIk,
    #[error("an identity key change has no endorsement")]
    Unendorsed,
    #[error("the signer is not a holder of the version before")]
    NotHolder,
    #[error("signed by a key this side did not compare")]
    NotCompared,
    #[error("r_N does not open the commitment")]
    Commitment,
    #[error("the person says the words differ")]
    SasMismatch,
    #[error("a step out of order, a second comparison or an ended session")]
    Session,
    #[error("another object at an id already held, or another record at an anchored version")]
    Conflict,
    #[error("the sealed destination differs from the record's")]
    Destination,
    #[error("the system random source failed")]
    Random,
    #[error("a team restart waits until the person compares the restarting owner's words")]
    RestartHeld,
}

impl KeysError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Suite { .. } => "keys.suite",
            Self::Encoding { .. } => "keys.encoding",
            Self::RecoveryKey => "keys.recovery_key",
            Self::Signature => "keys.signature",
            Self::PublicKey => "keys.public_key",
            Self::Open => "keys.open",
            Self::Mismatch { .. } => "keys.mismatch",
            Self::Kid => "keys.kid",
            Self::Ring => "keys.ring",
            Self::Stale { .. } => "keys.stale",
            Self::Step { .. } => "keys.step",
            Self::RetiredIk => "keys.retired_ik",
            Self::Unendorsed => "keys.unendorsed",
            Self::NotHolder => "keys.not_holder",
            Self::NotCompared => "keys.not_compared",
            Self::Commitment => "keys.commitment",
            Self::SasMismatch => "keys.sas_mismatch",
            Self::Session => "keys.session",
            Self::Conflict => "keys.conflict",
            Self::Destination => "keys.destination",
            Self::Random => "keys.random",
            Self::RestartHeld => "keys.restart_held",
        }
    }

    pub(crate) fn encoding(what: &'static str) -> Self {
        Self::Encoding { what }
    }
}

#[cfg(test)]
mod tests {
    use super::KeysError;

    #[test]
    fn every_code_is_distinct_and_in_the_keys_namespace() {
        let all = [
            KeysError::Suite { found: String::new() },
            KeysError::Encoding { what: "" },
            KeysError::RecoveryKey,
            KeysError::Signature,
            KeysError::PublicKey,
            KeysError::Open,
            KeysError::Mismatch { what: "" },
            KeysError::Kid,
            KeysError::Ring,
            KeysError::Stale { held: 0, offered: 0 },
            KeysError::Step { held: 0, offered: 0 },
            KeysError::RetiredIk,
            KeysError::Unendorsed,
            KeysError::NotHolder,
            KeysError::NotCompared,
            KeysError::Commitment,
            KeysError::SasMismatch,
            KeysError::Session,
            KeysError::Conflict,
            KeysError::Destination,
            KeysError::Random,
            KeysError::RestartHeld,
        ];
        let mut codes: Vec<_> = all.iter().map(KeysError::code).collect();
        assert!(codes.iter().all(|code| code.starts_with("keys.")));
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), all.len());
    }
}
