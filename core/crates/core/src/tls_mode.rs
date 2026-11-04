use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    Disable,
    Require,
    VerifyFull,
    /// TLS before the first protocol byte, as SQL Server's TDS 8.0 strict
    /// encryption does, with the certificate checked as in `VerifyFull`.
    /// Microsoft's drivers refuse to skip the check in this mode.
    Strict,
}

impl TlsMode {
    /// Whether the server's certificate must chain to a trusted root and
    /// carry the server's name.
    pub fn verifies_certificate(self) -> bool {
        matches!(self, Self::VerifyFull | Self::Strict)
    }

    pub fn encrypts(self) -> bool {
        self != Self::Disable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_verifies_like_verify_full_and_is_stored_as_strict() {
        assert!(TlsMode::Strict.verifies_certificate());
        assert!(TlsMode::VerifyFull.verifies_certificate());
        assert!(!TlsMode::Require.verifies_certificate());
        assert!(!TlsMode::Disable.encrypts());
        assert!(TlsMode::Strict.encrypts());
        assert_eq!(
            serde_json::to_string(&TlsMode::Strict).ok().as_deref(),
            Some("\"strict\"")
        );
    }
}
