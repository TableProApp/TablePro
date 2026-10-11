use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// TLS verification mode for network drivers.
///
/// `Disabled` sends plaintext. `Prefer` / `Require` encrypt without
/// authenticating the server (legacy / TOFU transition). `VerifyCa`
/// checks the certificate chain. `VerifyFull` also checks the hostname.
/// New network connections default to `VerifyFull`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    Disabled,
    Prefer,
    Require,
    VerifyCa,
    #[default]
    VerifyFull,
}

impl TlsMode {
    pub const ALL: [Self; 5] = [
        Self::Disabled,
        Self::Prefer,
        Self::Require,
        Self::VerifyCa,
        Self::VerifyFull,
    ];

    pub fn encrypts(self) -> bool {
        !matches!(self, Self::Disabled)
    }

    pub fn verifies_cert(self) -> bool {
        matches!(self, Self::VerifyCa | Self::VerifyFull)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Disabled => "Disabled",
            Self::Prefer => "Prefer",
            Self::Require => "Require",
            Self::VerifyCa => "Verify CA",
            Self::VerifyFull => "Verify Full",
        }
    }

    pub fn from_index(index: u32) -> Self {
        Self::ALL.get(index as usize).copied().unwrap_or(Self::VerifyFull)
    }

    pub fn index(self) -> u32 {
        Self::ALL.iter().position(|m| *m == self).unwrap_or(4) as u32
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TlsConfig {
    pub mode: TlsMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root_cert: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_cert: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_key: Option<PathBuf>,
    /// Optional SHA-256 fingerprint (hex, lowercase) accepted when the
    /// presented certificate fails normal chain verification. Reuses the
    /// TOFU pattern from SSH known_hosts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_fingerprint: Option<String>,
}

impl TlsConfig {
    pub fn disabled() -> Self {
        Self {
            mode: TlsMode::Disabled,
            ..Default::default()
        }
    }
}

/// Deployment environment for a saved connection. Drives policy defaults:
/// Prod agents are read-only; human writes on Prod require approval.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Environment {
    #[default]
    Local,
    Dev,
    Staging,
    Prod,
}

impl Environment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Dev => "dev",
            Self::Staging => "staging",
            Self::Prod => "prod",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Local => "Local",
            Self::Dev => "Dev",
            Self::Staging => "Staging",
            Self::Prod => "Prod",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tls_mode_index_round_trips() {
        for mode in TlsMode::ALL {
            assert_eq!(TlsMode::from_index(mode.index()), mode);
        }
        assert_eq!(TlsMode::from_index(99), TlsMode::VerifyFull);
    }
}

/// Flattens an error and every `source()` behind it into one string, so a
/// cause buried under a generic transport error is still searchable.
pub fn error_chain_text(err: &dyn std::error::Error) -> String {
    let mut parts = Vec::new();
    let mut current = Some(err);
    while let Some(error) = current {
        parts.push(error.to_string());
        current = error.source();
    }
    parts.join(" ")
}

/// Several engines report a failed TLS handshake as a generic I/O or
/// connection error, so the cause only survives in the message text. A
/// driver pairs this with its own check that the error kind could be
/// hiding a handshake failure; text alone must not reclassify an error.
pub fn looks_like_tls_failure(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("certificate")
        || lower.contains("notvalidforname")
        || lower.contains("not valid for name")
        || lower.contains("hostname")
        || lower.contains("invaliddnsname")
        || lower.contains("tls handshake")
        || lower.contains("unknown issuer")
        || lower.contains("unknown ca")
}

#[cfg(test)]
mod shared_tls_error_tests {
    use super::*;

    #[derive(Debug)]
    struct Layer {
        message: &'static str,
        source: Option<Box<Layer>>,
    }

    impl std::fmt::Display for Layer {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.message)
        }
    }

    impl std::error::Error for Layer {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            self.source
                .as_ref()
                .map(|inner| inner.as_ref() as &(dyn std::error::Error + 'static))
        }
    }

    #[test]
    fn the_chain_keeps_every_nested_cause() {
        let error = Layer {
            message: "connection refused",
            source: Some(Box::new(Layer {
                message: "invalid peer certificate: NotValidForName",
                source: None,
            })),
        };
        let text = error_chain_text(&error);
        assert!(text.contains("connection refused"));
        assert!(text.contains("NotValidForName"));
    }

    #[test]
    fn a_handshake_cause_is_recognised_only_through_the_whole_chain() {
        let error = Layer {
            message: "connection refused",
            source: Some(Box::new(Layer {
                message: "certificate not valid for name \"127.0.0.1\"",
                source: None,
            })),
        };
        assert!(!looks_like_tls_failure(&error.to_string()));
        assert!(looks_like_tls_failure(&error_chain_text(&error)));
    }

    #[test]
    fn an_ordinary_connection_error_is_not_a_handshake_failure() {
        assert!(!looks_like_tls_failure("Connection refused"));
        assert!(!looks_like_tls_failure("no route to host"));
    }

    #[test]
    fn rustls_identity_wording_is_recognised() {
        assert!(looks_like_tls_failure("invalid peer certificate: NotValidForName"));
        assert!(looks_like_tls_failure("unknown issuer"));
        assert!(looks_like_tls_failure("TLS handshake eof"));
    }
}
