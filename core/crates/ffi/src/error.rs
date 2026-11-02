use std::path::Path;
use std::sync::Arc;

use tablepro_core::{DriverError, ServerDiagnostics, TransportError};
use tablepro_session::{ConnectError, OperationError};

/// Why a call produced no value. A cancel is its own variant, so a
/// binding can turn it into its language's cancellation.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("cancelled")]
    Cancelled,
    #[error("{}", info.message)]
    Failed { info: ErrorInfo },
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
            info: ErrorInfo {
                code: code.to_owned(),
                codes: vec![code.to_owned()],
                message: message.into(),
                server: None,
                path: None,
            },
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
        }
    }

    fn plain(codes: &[&str], message: String) -> Self {
        Self {
            code: codes.last().map(|code| (*code).to_owned()).unwrap_or_default(),
            codes: codes.iter().map(|code| (*code).to_owned()).collect(),
            message,
            server: None,
            path: None,
        }
    }
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
                info: ErrorInfo::from_driver(&error),
            },
        }
    }
}

impl From<&OperationError> for CoreError {
    fn from(error: &OperationError) -> Self {
        match error {
            OperationError::Cancelled | OperationError::Driver(DriverError::Cancelled) => Self::Cancelled,
            OperationError::Driver(driver) => Self::Failed {
                info: ErrorInfo::wrapping(&[error.code()], driver, error.to_string()),
            },
            other => Self::Failed {
                info: ErrorInfo::plain(&[other.code()], other.to_string()),
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
                info: ErrorInfo::wrapping(&[error.code()], driver, error.to_string()),
            },
            ConnectError::Keyring(keyring) => Self::Failed {
                info: ErrorInfo::plain(&[error.code(), keyring.code()], error.to_string()),
            },
            other => Self::Failed {
                info: ErrorInfo::plain(&[other.code()], other.to_string()),
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
            CoreError::Failed { info } => info,
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
