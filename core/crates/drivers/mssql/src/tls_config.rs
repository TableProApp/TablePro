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
        if tls.mode == TlsMode::Prefer {
            return Err(DriverError::Config(ConfigError::UnsupportedTlsMode));
        }
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
            TlsMode::Prefer | TlsMode::Require => {
                config.encryption(EncryptionLevel::Required);
                config.trust_cert();
            }
            TlsMode::VerifyFull => {
                config.encryption(EncryptionLevel::Required);
                self.verify(config);
            }
            TlsMode::Strict => {
                config.encryption(EncryptionLevel::Strict);
                self.verify(config);
            }
        }
    }

    fn verify(&self, config: &mut Config) {
        // Added to the system roots, not in place of them.
        if let Some(ca_file) = &self.ca_file {
            config.trust_cert_ca(ca_file.to_string_lossy());
        }
        if let Some(server_name) = &self.server_name {
            config.hostname_in_certificate(server_name);
        }
    }

    pub(crate) fn mode(&self) -> TlsMode {
        self.mode
    }

    /// The name the certificate is checked against on a login to `host`.
    pub(crate) fn server_name<'a>(&'a self, host: &'a str) -> &'a str {
        self.server_name.as_deref().unwrap_or(host)
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
            TlsMode::Prefer | TlsMode::Require | TlsMode::VerifyFull | TlsMode::Strict => failure,
        }
    }

    /// The failure of a login the server hung up on without a byte while
    /// it answers the other way to begin one: a strict TLS hello it cannot
    /// read, or a TDS 7 pre-login when it allows only strict TLS.
    pub(crate) fn opening_refused(&self, detail: String) -> DriverError {
        let failure = match self.mode {
            TlsMode::Strict => TlsFailure::ServerRefusedStrict,
            TlsMode::Disable | TlsMode::Prefer | TlsMode::Require | TlsMode::VerifyFull => {
                TlsFailure::ServerRequiresStrict
            }
        };
        DriverError::Tls { failure, detail }
    }
}

/// The text of a failure that is the server closing the stream.
pub(crate) fn hung_up(error: &Error) -> Option<&str> {
    match error {
        Error::Io {
            kind:
                IoErrorKind::UnexpectedEof
                | IoErrorKind::ConnectionReset
                | IoErrorKind::ConnectionAborted
                | IoErrorKind::BrokenPipe,
            message,
        } => Some(message),
        _ => None,
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
    fn strict_starts_tls_first_and_checks_the_certificate() {
        let strict = TlsPlan {
            mode: TlsMode::Strict,
            ca_file: Some(PathBuf::from("/etc/tablepro/ca.pem")),
            server_name: Some("db.tablepro.test".to_owned()),
        };
        let mut config = Config::new();
        strict.apply(&mut config);
        let described = format!("{config:?}");

        assert!(described.contains("encryption: Strict"), "{described}");
        assert!(described.contains("bypass: false"), "{described}");
        assert!(described.contains("/etc/tablepro/ca.pem"), "{described}");
        assert!(
            described.contains("hostname_in_certificate: Some(\"db.tablepro.test\")"),
            "{described}"
        );
    }

    #[test]
    fn a_refused_opening_names_the_mode_the_server_takes() {
        let failure = |mode| match plan(mode).opening_refused("tls handshake eof".to_owned()) {
            DriverError::Tls { failure, .. } => Some(failure),
            _ => None,
        };

        assert_eq!(failure(TlsMode::Strict), Some(TlsFailure::ServerRefusedStrict));
        for mode in [TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull] {
            assert_eq!(failure(mode), Some(TlsFailure::ServerRequiresStrict), "{mode:?}");
        }
    }

    #[test]
    fn only_a_closed_stream_is_a_hang_up() {
        let io = |kind| Error::Io {
            kind,
            message: "failed to fill whole buffer".to_owned(),
        };

        for kind in [
            IoErrorKind::UnexpectedEof,
            IoErrorKind::ConnectionReset,
            IoErrorKind::ConnectionAborted,
            IoErrorKind::BrokenPipe,
        ] {
            assert_eq!(hung_up(&io(kind)), Some("failed to fill whole buffer"), "{kind:?}");
        }
        assert_eq!(hung_up(&io(IoErrorKind::TimedOut)), None);
        assert_eq!(hung_up(&Error::Tls("received fatal alert".to_owned())), None);
        assert_eq!(
            plan(TlsMode::VerifyFull).login_error(io(IoErrorKind::UnexpectedEof)),
            DriverError::ConnectionLost {
                during: LossPhase::Connect
            }
        );
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
