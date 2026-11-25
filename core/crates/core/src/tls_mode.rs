use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    Disable,
    /// TLS when the server offers it, otherwise the clear, with the
    /// certificate not checked: libpq's `prefer` and the mysql client's
    /// `PREFERRED`.
    Prefer,
    Require,
    /// The certificate chains to a trusted root or the CA file, and the
    /// server's name is not checked: libpq's `verify-ca` and the mysql
    /// client's `VERIFY_CA`. No engine offers it until its driver checks
    /// the chain without the name, so a connection saved with it is
    /// refused at connect.
    VerifyCa,
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
        matches!(self, Self::VerifyCa | Self::VerifyFull | Self::Strict)
    }

    /// Whether the certificate must also carry the server's name.
    pub fn verifies_host_name(self) -> bool {
        matches!(self, Self::VerifyFull | Self::Strict)
    }

    /// Whether the client asks the server for TLS.
    pub fn encrypts(self) -> bool {
        self != Self::Disable
    }

    /// Whether a server that does not take TLS is refused rather than
    /// reached in the clear.
    pub fn requires_tls(self) -> bool {
        !matches!(self, Self::Disable | Self::Prefer)
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

    #[test]
    fn verify_ca_checks_the_chain_and_not_the_name() {
        assert!(TlsMode::VerifyCa.verifies_certificate());
        assert!(!TlsMode::VerifyCa.verifies_host_name());
        assert!(TlsMode::VerifyFull.verifies_host_name());
        assert!(TlsMode::VerifyCa.requires_tls());
        assert_eq!(
            serde_json::to_string(&TlsMode::VerifyCa).ok().as_deref(),
            Some("\"verify_ca\"")
        );
    }

    #[test]
    fn prefer_asks_for_tls_without_requiring_or_checking_it() {
        assert!(TlsMode::Prefer.encrypts());
        assert!(!TlsMode::Prefer.requires_tls());
        assert!(!TlsMode::Prefer.verifies_certificate());
        assert!(TlsMode::Require.requires_tls());
        assert!(!TlsMode::Disable.requires_tls());
        assert_eq!(
            serde_json::to_string(&TlsMode::Prefer).ok().as_deref(),
            Some("\"prefer\"")
        );
    }
}
