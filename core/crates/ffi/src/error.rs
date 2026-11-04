use std::path::Path;
use std::sync::Arc;

use tablepro_core::{DriverError, ServerDiagnostics, SshFailure, TransportError};
use tablepro_session::{ConnectError, OperationError};

use crate::host::SecretKindTag;

/// Why a call produced no value. A cancel is its own variant, so a
/// binding can turn it into its language's cancellation.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("cancelled")]
    Cancelled,
    #[error("{}", info.message)]
    Failed { info: BoxedErrorInfo },
}

/// An error as the app words it: by `code`, the innermost of `codes`,
/// which run from the outermost error in. `message` is English for the
/// log only.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ErrorInfo {
    pub code: String,
    pub codes: Vec<String>,
    pub message: String,
    /// What the server said, in its own words, which the app shows as
    /// it came.
    pub server: Option<ServerMessage>,
    /// The file an error about a database file names.
    pub path: Option<String>,
    /// The secret a keyring error is about, so the app can ask for it.
    pub secret: Option<SecretKindTag>,
    pub host_key: Option<HostKeyFailure>,
}

// Error details stay off the stack while bindings keep the same record values.
pub type BoxedErrorInfo = Box<ErrorInfo>;

uniffi::custom_type!(BoxedErrorInfo, ErrorInfo, {
    lower: |value| *value,
    try_lift: |value| Ok(Box::new(value)),
});

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostKeyFailure {
    pub host: String,
    pub algorithm: String,
    pub fingerprint: String,
    pub known_hosts: String,
    pub line: u64,
    pub trust_allowed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerMessage {
    pub message: String,
    pub code: Option<String>,
    pub sqlstate: Option<String>,
    pub detail: Option<String>,
    pub hint: Option<String>,
    pub position: Option<u32>,
}

impl CoreError {
    pub(crate) fn failed(code: &str, message: impl Into<String>) -> Self {
        Self::Failed {
            info: Box::new(ErrorInfo {
                code: code.to_owned(),
                codes: vec![code.to_owned()],
                message: message.into(),
                server: None,
                path: None,
                secret: None,
                host_key: None,
            }),
        }
    }

    pub fn code(&self) -> &str {
        match self {
            Self::Cancelled => "cancelled",
            Self::Failed { info } => &info.code,
        }
    }
}

impl ErrorInfo {
    pub(crate) fn from_driver(error: &DriverError) -> Self {
        Self::wrapping(&[], error, error.to_string())
    }

    fn wrapping(outer: &[&str], error: &DriverError, message: String) -> Self {
        let mut codes: Vec<String> = outer.iter().map(|code| (*code).to_owned()).collect();
        driver_codes(error, &mut codes);
        let cause = error.cause();
        Self {
            code: codes.last().cloned().unwrap_or_default(),
            codes,
            message,
            server: server_message(cause),
            path: file_path(cause).map(|path| path.display().to_string()),
            secret: None,
            host_key: host_key_failure(cause),
        }
    }

    fn plain(codes: &[&str], message: String) -> Self {
        Self {
            code: codes.last().map(|code| (*code).to_owned()).unwrap_or_default(),
            codes: codes.iter().map(|code| (*code).to_owned()).collect(),
            message,
            server: None,
            path: None,
            secret: None,
            host_key: None,
        }
    }
}

fn host_key_failure(error: &DriverError) -> Option<HostKeyFailure> {
    let DriverError::Transport(TransportError::Ssh(SshFailure::HostKeyChanged {
        host,
        algorithm,
        sha256_fingerprint,
        known_hosts,
        line,
        trust_allowed,
    })) = error
    else {
        return None;
    };
    Some(HostKeyFailure {
        host: host.clone(),
        algorithm: algorithm.clone(),
        fingerprint: sha256_fingerprint.clone(),
        known_hosts: known_hosts.display().to_string(),
        line: u64::try_from(*line).unwrap_or(u64::MAX),
        trust_allowed: *trust_allowed,
    })
}

fn driver_codes(error: &DriverError, codes: &mut Vec<String>) {
    codes.push(error.code().to_owned());
    match error {
        DriverError::Transport(transport) => {
            codes.push(transport.code().to_owned());
            if let TransportError::Ssh(failure) = transport {
                codes.push(failure.code().to_owned());
            }
        }
        DriverError::Config(config) => codes.push(config.code().to_owned()),
        DriverError::RolledBack { source, .. }
        | DriverError::CommitOutcomeUnknown { source, .. }
        | DriverError::PartiallyApplied { source, .. } => driver_codes(source, codes),
        _ => {}
    }
}

fn server_message(error: &DriverError) -> Option<ServerMessage> {
    let diagnostics: &ServerDiagnostics = match error {
        DriverError::Server(diagnostics) | DriverError::LoginRefused(diagnostics) => diagnostics,
        DriverError::Auth {
            diagnostics: Some(diagnostics),
        } => diagnostics,
        _ => return None,
    };
    Some(ServerMessage {
        message: diagnostics.message.clone(),
        code: diagnostics.code.as_ref().map(ToString::to_string),
        sqlstate: diagnostics.sqlstate().map(str::to_owned),
        detail: diagnostics.detail.clone(),
        hint: diagnostics.hint.clone(),
        position: diagnostics.position,
    })
}

fn file_path(error: &DriverError) -> Option<&Path> {
    match error {
        DriverError::FileNotFound { path }
        | DriverError::FileAccessDenied { path }
        | DriverError::NotADatabase { path }
        | DriverError::FileIo { path, .. } => Some(path),
        _ => None,
    }
}

impl From<DriverError> for CoreError {
    fn from(error: DriverError) -> Self {
        match error {
            DriverError::Cancelled => Self::Cancelled,
            error => Self::Failed {
                info: ErrorInfo::from_driver(&error).into(),
            },
        }
    }
}

impl From<&OperationError> for CoreError {
    fn from(error: &OperationError) -> Self {
        match error {
            OperationError::Cancelled | OperationError::Driver(DriverError::Cancelled) => Self::Cancelled,
            OperationError::Driver(driver) => Self::Failed {
                info: ErrorInfo::wrapping(&[error.code()], driver, error.to_string()).into(),
            },
            other => Self::Failed {
                info: ErrorInfo::plain(&[other.code()], other.to_string()).into(),
            },
        }
    }
}

impl From<OperationError> for CoreError {
    fn from(error: OperationError) -> Self {
        Self::from(&error)
    }
}

impl From<Arc<OperationError>> for CoreError {
    fn from(error: Arc<OperationError>) -> Self {
        Self::from(error.as_ref())
    }
}

impl From<ConnectError> for CoreError {
    fn from(error: ConnectError) -> Self {
        match &error {
            ConnectError::Cancelled | ConnectError::Driver(DriverError::Cancelled) => Self::Cancelled,
            ConnectError::Driver(driver) => Self::Failed {
                info: ErrorInfo::wrapping(&[error.code()], driver, error.to_string()).into(),
            },
            ConnectError::Keyring(keyring) => Self::Failed {
                info: Box::new(ErrorInfo {
                    secret: Some(keyring.kind().into()),
                    ..ErrorInfo::plain(&[error.code(), keyring.code()], error.to_string())
                }),
            },
            other => Self::Failed {
                info: ErrorInfo::plain(&[other.code()], other.to_string()).into(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::{ConfigError, ServerCode};

    use super::*;

    fn info(error: CoreError) -> ErrorInfo {
        match error {
            CoreError::Failed { info } => *info,
            CoreError::Cancelled => panic!("cancelled"),
        }
    }

    #[test]
    fn a_wrapped_error_names_every_layer_and_the_innermost_decides() {
        let error = ConnectError::Driver(DriverError::FileNotFound {
            path: PathBuf::from("/srv/app.db"),
        });

        let info = info(error.into());

        assert_eq!(info.codes, ["connect.driver", "driver.file_not_found"]);
        assert_eq!(info.code, "driver.file_not_found");
        assert_eq!(
            info.path.as_deref(),
            Some(Path::new("/srv/app.db").display().to_string().as_str())
        );
    }

    #[test]
    fn a_config_error_carries_its_own_code() {
        let info = info(OperationError::Driver(DriverError::Config(ConfigError::RelativePath)).into());

        assert_eq!(
            info.codes,
            ["operation.driver", "driver.config", "config.relative_path"]
        );
    }

    #[test]
    fn a_changed_host_key_carries_the_facts_needed_for_an_explicit_recovery() {
        let known_hosts = PathBuf::from("/keys/known_hosts");
        for trust_allowed in [false, true] {
            let error = ConnectError::Driver(DriverError::from(TransportError::Ssh(SshFailure::HostKeyChanged {
                host: "[db.internal]:2222".to_owned(),
                algorithm: "ED25519".to_owned(),
                sha256_fingerprint: "SHA256:new-key".to_owned(),
                known_hosts: known_hosts.clone(),
                line: 7,
                trust_allowed,
            })));

            let info = info(error.into());

            assert_eq!(info.code, "ssh.host_key_changed");
            assert_eq!(
                info.host_key,
                Some(HostKeyFailure {
                    host: "[db.internal]:2222".to_owned(),
                    algorithm: "ED25519".to_owned(),
                    fingerprint: "SHA256:new-key".to_owned(),
                    known_hosts: known_hosts.display().to_string(),
                    line: 7,
                    trust_allowed,
                })
            );
        }
    }

    #[test]
    fn a_revoked_host_key_has_no_recovery_action() {
        let info = info(
            DriverError::from(TransportError::Ssh(SshFailure::HostKeyRevoked {
                host: "db.internal".to_owned(),
                detail: "revoked".to_owned(),
            }))
            .into(),
        );

        assert_eq!(info.code, "ssh.host_key_revoked");
        assert!(info.host_key.is_none());
    }

    #[test]
    fn the_server_s_words_come_through_as_they_came() {
        let mut diagnostics = ServerDiagnostics::new(
            Some(ServerCode::Sqlite {
                primary: 1,
                extended: 1,
            }),
            "no such table: nope",
        );
        diagnostics.position = Some(15);

        let info = info(DriverError::reported(diagnostics).into());

        let server = info.server.expect("the server's message");
        assert_eq!(info.code, "driver.server");
        assert_eq!(server.message, "no such table: nope");
        assert_eq!(server.code.as_deref(), Some("1"));
        assert_eq!(server.position, Some(15));
    }

    #[test]
    fn every_kind_of_cancel_is_a_cancel() {
        assert_eq!(CoreError::from(DriverError::Cancelled), CoreError::Cancelled);
        assert_eq!(CoreError::from(OperationError::Cancelled), CoreError::Cancelled);
        assert_eq!(
            CoreError::from(OperationError::Driver(DriverError::Cancelled)),
            CoreError::Cancelled
        );
        assert_eq!(CoreError::from(ConnectError::Cancelled), CoreError::Cancelled);
    }
}
