use std::path::PathBuf;

use tablepro_core::{ConfigError, DriverError, LossPhase, TimeoutPhase, TlsConfig, TlsFailure, TlsMode};
use tiberius::error::{Error, IoErrorKind};
use tiberius::{Config, EncryptionLevel};

use crate::errors::map_error;

/// What tiberius says when the server will not encrypt and the client
/// asked it to.
const ENCRYPTION_REFUSED: &str = "does not allow the requested encryption level";

/// rustls failures as their text reaches us through tiberius, which
/// keeps only the message. The first match wins, so a specific phrase
/// comes before a general one.
const RUSTLS_TEXT: &[(&str, TlsFailure)] = &[
    ("UnknownIssuer", TlsFailure::UnknownIssuer),
    ("NotValidForName", TlsFailure::NameMismatch),
    ("not valid for name", TlsFailure::NameMismatch),
    ("NotValidYet", TlsFailure::NotYetValid),
    ("not valid yet", TlsFailure::NotYetValid),
    ("certificate expired", TlsFailure::Expired),
    ("Expired", TlsFailure::Expired),
    ("Revoked", TlsFailure::Revoked),
    ("received fatal alert", TlsFailure::HandshakeRejected),
    ("AlertReceived", TlsFailure::HandshakeRejected),
    ("peer is incompatible", TlsFailure::HandshakeRejected),
    // tokio-rustls, when the server closes the socket mid-handshake. With
    // Disable, tiberius starts that handshake only because the server
    // demanded encryption, and the server then hangs up on a client that
    // said it has none.
    ("tls handshake eof", TlsFailure::HandshakeRejected),
    ("invalid peer certificate", TlsFailure::Other),
    ("CA certificates", TlsFailure::Other),
    ("platform certificates", TlsFailure::Other),
];

/// How every login to one target negotiates TLS.
///
/// tiberius takes no rustls `ClientConfig`, so trust is what its own
/// settings express: the system roots plus the CA file for full
/// verification, and no verification for Require. A verifier that
/// records what it saw cannot be installed either, so a failure is
/// told apart by the text rustls gave it, which is coarser than the
/// other engines' classification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TlsPlan {
    mode: TlsMode,
    ca_file: Option<PathBuf>,
    server_name: Option<String>,
}

impl TlsPlan {
    pub(crate) fn new(tls: &TlsConfig) -> Result<Self, DriverError> {
        if tls.client_identity.is_some() {
            return Err(DriverError::Config(ConfigError::ClientIdentityUnsupported));
        }
        // tiberius reads the CA file during the handshake and reports a
        // bad one as an I/O error, so it is checked here, where the
        // problem can still be named.
        tablepro_net::tls::check_pem_files(tls)?;
        Ok(Self {
            mode: tls.mode,
            ca_file: tls.ca_file.clone(),
            server_name: tls.server_name.clone(),
        })
    }

    pub(crate) fn apply(&self, config: &mut Config) {
        match self.mode {
            TlsMode::Disable => config.encryption(EncryptionLevel::NotSupported),
            TlsMode::Require => {
                config.encryption(EncryptionLevel::Required);
                config.trust_cert();
            }
            TlsMode::VerifyFull => {
                config.encryption(EncryptionLevel::Required);
                // Added to the system roots, not in place of them.
                if let Some(ca_file) = &self.ca_file {
                    config.trust_cert_ca(ca_file.to_string_lossy());
                }
                if let Some(server_name) = &self.server_name {
                    config.hostname_in_certificate(server_name);
                }
            }
        }
    }

    /// What a failed login means, given what was asked of TLS.
    pub(crate) fn login_error(&self, error: Error) -> DriverError {
        match error {
            Error::Tls(detail) => DriverError::Tls {
                failure: self.handshake_failure(tls_failure(&detail)),
                detail,
            },
            Error::Protocol(text) if text.contains(ENCRYPTION_REFUSED) => DriverError::Tls {
                failure: TlsFailure::ServerRefusedTls,
                detail: text.into_owned(),
            },
            Error::Io {
                kind: IoErrorKind::TimedOut,
                ..
            } => DriverError::Timeout {
                phase: TimeoutPhase::Login,
                server_cancelled: false,
            },
            Error::Io { message, .. } => match recognise(&message) {
                Some(failure) => DriverError::Tls {
                    failure: self.handshake_failure(failure),
                    detail: message,
                },
                None => DriverError::ConnectionLost {
                    during: LossPhase::Connect,
                },
            },
            other => map_error(other),
        }
    }

    /// A handshake on a connection that asked for no TLS at all can only
    /// be the server insisting on it.
    fn handshake_failure(&self, failure: TlsFailure) -> TlsFailure {
        match self.mode {
            TlsMode::Disable => TlsFailure::ServerRequiresTls,
            TlsMode::Require | TlsMode::VerifyFull => failure,
        }
    }
}

/// The failure a rustls message names, `Other` when it names none.
pub(crate) fn tls_failure(text: &str) -> TlsFailure {
    recognise(text).unwrap_or(TlsFailure::Other)
}

fn recognise(text: &str) -> Option<TlsFailure> {
    RUSTLS_TEXT
        .iter()
        .find(|(phrase, _)| text.contains(phrase))
        .map(|(_, failure)| *failure)
}

#[cfg(test)]
mod tests {
    use tablepro_core::ErrorCategory;

    use super::*;

    fn plan(mode: TlsMode) -> TlsPlan {
        TlsPlan {
            mode,
            ca_file: None,
            server_name: None,
        }
    }

    #[test]
    fn tls_text_classification_table() {
        let rejected = "the server's certificate was rejected during the TLS handshake: ";
        let cases = [
            (format!("{rejected}UnknownIssuer."), TlsFailure::UnknownIssuer),
            (
                format!(
                    "{rejected}certificate not valid for name \"wrong.tablepro.test\"; certificate is only valid for DnsName(\"localhost\")."
                ),
                TlsFailure::NameMismatch,
            ),
            (
                "invalid peer certificate: NotValidForName".to_owned(),
                TlsFailure::NameMismatch,
            ),
            (
                format!(
                    "{rejected}certificate expired: verification time 1 (UNIX), but certificate is not valid after 0"
                ),
                TlsFailure::Expired,
            ),
            (
                format!("{rejected}certificate not valid yet: verification time 0 (UNIX)"),
                TlsFailure::NotYetValid,
            ),
            (format!("{rejected}Revoked."), TlsFailure::Revoked),
            (
                "received fatal alert: HandshakeFailure".to_owned(),
                TlsFailure::HandshakeRejected,
            ),
            (
                format!("{rejected}Other(OtherError(UnsupportedCertVersion))."),
                TlsFailure::Other,
            ),
            ("something nobody expected".to_owned(), TlsFailure::Other),
        ];
        for (text, expected) in cases {
            assert_eq!(tls_failure(&text), expected, "{text}");
        }
    }

    #[test]
    fn disable_against_forced_encryption_requires_tls() {
        let error =
            plan(TlsMode::Disable).login_error(Error::Tls("invalid peer certificate: UnknownIssuer".to_owned()));

        assert!(matches!(
            error,
            DriverError::Tls {
                failure: TlsFailure::ServerRequiresTls,
                ..
            }
        ));
        assert_eq!(error.category(), ErrorCategory::Tls);
    }

    #[test]
    fn disable_against_a_server_that_hangs_up_mid_handshake_requires_tls() {
        let eof = || Error::Io {
            kind: IoErrorKind::UnexpectedEof,
            message: "tls handshake eof".to_owned(),
        };

        assert!(matches!(
            plan(TlsMode::Disable).login_error(eof()),
            DriverError::Tls {
                failure: TlsFailure::ServerRequiresTls,
                ..
            }
        ));
        assert!(matches!(
            plan(TlsMode::Require).login_error(eof()),
            DriverError::Tls {
                failure: TlsFailure::HandshakeRejected,
                ..
            }
        ));
    }

    #[test]
    fn a_server_that_declines_encryption_refused_tls() {
        let error = plan(TlsMode::Require).login_error(Error::Protocol(
            "Server does not allow the requested encryption level.".into(),
        ));

        assert!(matches!(
            error,
            DriverError::Tls {
                failure: TlsFailure::ServerRefusedTls,
                ..
            }
        ));
    }

    #[test]
    fn login_io_failures_are_told_apart() {
        let verify = plan(TlsMode::VerifyFull);
        let timed_out = verify.login_error(Error::Io {
            kind: IoErrorKind::TimedOut,
            message: "handshake timed out".to_owned(),
        });
        let alert = verify.login_error(Error::Io {
            kind: IoErrorKind::InvalidData,
            message: "received fatal alert: HandshakeFailure".to_owned(),
        });
        let reset = verify.login_error(Error::Io {
            kind: IoErrorKind::ConnectionReset,
            message: "connection reset by peer".to_owned(),
        });

        assert!(matches!(
            timed_out,
            DriverError::Timeout {
                phase: TimeoutPhase::Login,
                ..
            }
        ));
        assert!(matches!(
            alert,
            DriverError::Tls {
                failure: TlsFailure::HandshakeRejected,
                ..
            }
        ));
        assert_eq!(
            reset,
            DriverError::ConnectionLost {
                during: LossPhase::Connect
            }
        );
    }

    #[test]
    fn verify_full_adds_the_ca_and_the_name_and_require_trusts_anything() {
        let verify = TlsPlan {
            mode: TlsMode::VerifyFull,
            ca_file: Some(PathBuf::from("/etc/tablepro/ca.pem")),
            server_name: Some("db.tablepro.test".to_owned()),
        };
        let mut config = Config::new();
        verify.apply(&mut config);
        let described = format!("{config:?}");

        assert!(described.contains("encryption: Required"), "{described}");
        assert!(described.contains("/etc/tablepro/ca.pem"), "{described}");
        assert!(described.contains("bypass: false"), "{described}");
        assert!(
            described.contains("hostname_in_certificate: Some(\"db.tablepro.test\")"),
            "{described}"
        );

        let mut config = Config::new();
        plan(TlsMode::Require).apply(&mut config);
        let described = format!("{config:?}");
        assert!(described.contains("bypass: true"), "{described}");

        let mut config = Config::new();
        plan(TlsMode::Disable).apply(&mut config);
        assert!(format!("{config:?}").contains("encryption: NotSupported"));
    }

    #[test]
    fn a_client_certificate_is_refused_before_anything_is_sent() {
        let tls = TlsConfig {
            client_identity: Some(tablepro_core::ClientIdentity {
                certificate: PathBuf::from("/tls/client.pem"),
                key: PathBuf::from("/tls/client.key"),
            }),
            ..TlsConfig::verify_full()
        };

        assert_eq!(
            TlsPlan::new(&tls),
            Err(DriverError::Config(ConfigError::ClientIdentityUnsupported))
        );
    }
}
