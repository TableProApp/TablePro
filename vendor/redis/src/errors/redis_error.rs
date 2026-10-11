use std::{error, fmt, io, sync::Arc};

use arcstr::ArcStr;

use crate::{
    ParsingError,
    errors::server_error::{ServerError, ServerErrorKind},
};

/// An enum of all error kinds.
#[derive(PartialEq, Eq, Copy, Clone, Debug)]
#[non_exhaustive]
pub enum ErrorKind {
    /// The parser failed to parse the server response.
    Parse,
    /// The authentication with the server failed.
    AuthenticationFailed,
    /// Operation failed because of a type mismatch.
    UnexpectedReturnType,
    /// An error that was caused because the parameter to the
    /// client were wrong.
    InvalidClientConfig,
    /// This kind is returned if the redis error is one that is
    /// not native to the system.  This is usually the case if
    /// the cause is another error.
    Io,
    /// An error raised that was identified on the client before execution.
    Client,
    /// An extension error.  This is an error created by the server
    /// that is not directly understood by the library.
    Extension,
    /// Requested name not found among masters returned by the sentinels
    MasterNameNotFoundBySentinel,
    /// No valid replicas found in the sentinels, for a given master name
    NoValidReplicasFoundBySentinel,
    /// At least one sentinel connection info is required
    EmptySentinelList,
    /// Used when a cluster connection cannot find a connection to a valid node.
    ClusterConnectionNotFound,
    /// An error returned from the server
    Server(ServerErrorKind),

    #[cfg(feature = "json")]
    /// Error Serializing a struct to JSON form
    Serialize,

    /// Redis Servers prior to v6.0.0 doesn't support RESP3.
    /// Try disabling resp3 option
    RESP3NotSupported,
}

/// Represents a redis error.
///
/// For the most part you should be using the Error trait to interact with this
/// rather than the actual struct.
#[derive(Clone)]
pub struct RedisError {
    repr: ErrorRepr,
}

#[cfg(feature = "json")]
impl From<serde_json::Error> for RedisError {
    fn from(serde_err: serde_json::Error) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Serialize,
                err: Arc::new(serde_err),
            },
        }
    }
}

#[derive(Debug, Clone)]
enum ErrorRepr {
    General(ErrorKind, &'static str, Option<ArcStr>),
    Internal {
        kind: ErrorKind,
        err: Arc<dyn error::Error + Send + Sync>,
    },
    Parsing(ParsingError),
    Server(ServerError),
    Pipeline(Arc<[(usize, ServerError)]>),
    TransactionAborted(Arc<[(usize, ServerError)]>),
}

impl PartialEq for RedisError {
    fn eq(&self, other: &Self) -> bool {
        match (&self.repr, &other.repr) {
            (&ErrorRepr::General(kind_a, _, _), &ErrorRepr::General(kind_b, _, _)) => {
                kind_a == kind_b
            }
            (ErrorRepr::Parsing(a), ErrorRepr::Parsing(b)) => *a == *b,
            (ErrorRepr::Server(a), ErrorRepr::Server(b)) => *a == *b,
            (ErrorRepr::Pipeline(a), ErrorRepr::Pipeline(b)) => *a == *b,
            _ => false,
        }
    }
}

impl From<io::Error> for RedisError {
    fn from(err: io::Error) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Io,
                err: Arc::new(err),
            },
        }
    }
}

#[cfg(feature = "tls-rustls")]
impl From<rustls::pki_types::InvalidDnsNameError> for RedisError {
    fn from(err: rustls::pki_types::InvalidDnsNameError) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Io,
                err: Arc::new(err),
            },
        }
    }
}

#[cfg(feature = "tls-rustls")]
impl From<rustls_native_certs::Error> for RedisError {
    fn from(err: rustls_native_certs::Error) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Io,
                err: Arc::new(err),
            },
        }
    }
}

impl From<(ErrorKind, &'static str)> for RedisError {
    fn from((kind, desc): (ErrorKind, &'static str)) -> Self {
        Self {
            repr: ErrorRepr::General(kind, desc, None),
        }
    }
}

impl From<(ErrorKind, &'static str, String)> for RedisError {
    fn from((kind, desc, detail): (ErrorKind, &'static str, String)) -> Self {
        Self {
            repr: ErrorRepr::General(kind, desc, Some(detail.into())),
        }
    }
}

impl error::Error for RedisError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match &self.repr {
            ErrorRepr::Internal { err, .. } => Some(err),
            ErrorRepr::Server(err) => Some(err),
            ErrorRepr::Parsing(err) => Some(err),
            _ => None,
        }
    }
}

impl fmt::Debug for RedisError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        fmt::Display::fmt(self, f)
    }
}

impl fmt::Display for RedisError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        match &self.repr {
            ErrorRepr::General(kind, desc, detail) => {
                desc.fmt(f)?;
                f.write_str(" - ")?;
                fmt::Debug::fmt(&kind, f)?;
                if let Some(detail) = detail {
                    f.write_str(": ")?;
                    detail.fmt(f)
                } else {
                    Ok(())
                }
            }
            ErrorRepr::Internal { err, .. } => err.fmt(f),
            ErrorRepr::Parsing(err) => err.fmt(f),
            ErrorRepr::Server(err) => err.fmt(f),
            ErrorRepr::Pipeline(items) => {
                if items.len() > 1 {
                    f.write_str("Pipeline failures: [")?;
                } else {
                    f.write_str("Pipeline failure: [")?;
                }
                let mut first = true;
                for (index, error) in items.iter() {
                    if first {
                        write!(f, "(Index {index}, error: {error})")?;
                        first = false;
                    } else {
                        write!(f, ", (Index {index}, error: {error})")?;
                    }
                }
                f.write_str("]")
            }
            ErrorRepr::TransactionAborted(items) => {
                f.write_str("Transaction aborted: [")?;

                let mut first = true;
                for (index, error) in items.iter() {
                    if first {
                        write!(f, "(Index {index}, error: {error})")?;
                        first = false;
                    } else {
                        write!(f, ", (Index {index}, error: {error})")?;
                    }
                }
                f.write_str("]")
            }
        }
    }
}

/// What method should be used if retrying this request.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum RetryMethod {
    /// Create a fresh connection, since the current connection is no longer usable.
    Reconnect,
    /// Don't retry, this is a permanent error.
    NoRetry,
    /// Retry immediately, this doesn't require a wait.
    RetryImmediately,
    /// Retry after sleeping to avoid overloading the external service.
    WaitAndRetry,
    /// The key has moved to a different node but we have to ask which node, this is only relevant for clusters.
    AskRedirect,
    /// The key has moved to a different node, this is only relevant for clusters.
    MovedRedirect,
    /// Reconnect the initial connection to the master cluster, this is only relevant for clusters.
    ReconnectFromInitialConnections,
    /// The slot map is stale (e.g. a write hit a node demoted to replica during failover).
    /// Refresh the topology, then retry by re-routing to the slot's owner. Only relevant for clusters.
    RefreshSlotsAndRetry,
}

/// Indicates a general failure in the library.
impl RedisError {
    /// Returns the kind of the error.
    pub fn kind(&self) -> ErrorKind {
        match &self.repr {
            ErrorRepr::General(kind, _, _) | ErrorRepr::Internal { kind, .. } => *kind,
            ErrorRepr::Parsing(_) => ErrorKind::Parse,
            ErrorRepr::Server(err) => match err.kind() {
                Some(kind) => ErrorKind::Server(kind),
                None => ErrorKind::Extension,
            },
            ErrorRepr::Pipeline(items) => items
                .first()
                .and_then(|item| item.1.kind().map(|kind| kind.into()))
                .unwrap_or(ErrorKind::Extension),
            ErrorRepr::TransactionAborted(..) => ErrorKind::Server(ServerErrorKind::ExecAbort),
        }
    }

    /// Returns the error detail.
    pub fn detail(&self) -> Option<&str> {
        match &self.repr {
            ErrorRepr::General(_, _, detail) => detail.as_ref().map(|detail| detail.as_str()),
            ErrorRepr::Parsing(err) => Some(&err.description),
            ErrorRepr::Server(err) => err.details(),
            _ => None,
        }
    }

    /// Returns the raw error code if available.
    pub fn code(&self) -> Option<&str> {
        match self.kind() {
            ErrorKind::Server(kind) => Some(kind.code()),
            _ => match &self.repr {
                ErrorRepr::Server(err) => Some(err.code()),
                _ => None,
            },
        }
    }

    /// Returns the name of the error category for display purposes.
    pub fn category(&self) -> &str {
        match self.kind() {
            ErrorKind::Server(ServerErrorKind::ResponseError) => "response error",
            ErrorKind::AuthenticationFailed => "authentication failed",
            ErrorKind::UnexpectedReturnType => "type error",
            ErrorKind::Server(ServerErrorKind::ExecAbort) => "script execution aborted",
            ErrorKind::Server(ServerErrorKind::BusyLoading) => "busy loading",
            ErrorKind::Server(ServerErrorKind::NoScript) => "no script",
            ErrorKind::InvalidClientConfig => "invalid client config",
            ErrorKind::Server(ServerErrorKind::Moved) => "key moved",
            ErrorKind::Server(ServerErrorKind::Ask) => "key moved (ask)",
            ErrorKind::Server(ServerErrorKind::TryAgain) => "try again",
            ErrorKind::Server(ServerErrorKind::ClusterDown) => "cluster down",
            ErrorKind::Server(ServerErrorKind::CrossSlot) => "cross-slot",
            ErrorKind::Server(ServerErrorKind::MasterDown) => "master down",
            ErrorKind::Io => "I/O error",
            ErrorKind::Extension => "extension error",
            ErrorKind::Client => "client error",
            ErrorKind::Server(ServerErrorKind::ReadOnly) => "read-only",
            ErrorKind::MasterNameNotFoundBySentinel => "master name not found by sentinel",
            ErrorKind::NoValidReplicasFoundBySentinel => "no valid replicas found by sentinel",
            ErrorKind::EmptySentinelList => "empty sentinel list",
            ErrorKind::Server(ServerErrorKind::NotBusy) => "not busy",
            ErrorKind::ClusterConnectionNotFound => "connection to node in cluster not found",
            #[cfg(feature = "json")]
            ErrorKind::Serialize => "serializing",
            ErrorKind::RESP3NotSupported => "resp3 is not supported by server",
            ErrorKind::Parse => "parse error",
            ErrorKind::Server(ServerErrorKind::NoSub) => {
                "Server declined unsubscribe related command in non-subscribed mode"
            }
            ErrorKind::Server(ServerErrorKind::NoPerm) => "",
        }
    }

    /// Indicates that this failure is an IO failure.
    pub fn is_io_error(&self) -> bool {
        self.kind() == ErrorKind::Io
    }

    pub(crate) fn as_io_error(&self) -> Option<&io::Error> {
        match &self.repr {
            ErrorRepr::Internal { err, .. } => err.downcast_ref(),
            _ => None,
        }
    }

    /// Indicates that this is a cluster error.
    pub fn is_cluster_error(&self) -> bool {
        matches!(
            self.kind(),
            ErrorKind::Server(ServerErrorKind::Moved)
                | ErrorKind::Server(ServerErrorKind::Ask)
                | ErrorKind::Server(ServerErrorKind::TryAgain)
                | ErrorKind::Server(ServerErrorKind::ClusterDown)
        )
    }

    /// Returns true if this error indicates that the connection was
    /// refused.  You should generally not rely much on this function
    /// unless you are writing unit tests that want to detect if a
    /// local server is available.
    pub fn is_connection_refusal(&self) -> bool {
        self.as_io_error().is_some_and(|err| {
            #[allow(clippy::match_like_matches_macro)]
            match err.kind() {
                io::ErrorKind::ConnectionRefused => true,
                // if we connect to a unix socket and the file does not
                // exist yet, then we want to treat this as if it was a
                // connection refusal.
                io::ErrorKind::NotFound => cfg!(unix),
                _ => false,
            }
        })
    }

    /// Returns true if error was caused by I/O time out.
    /// Note that this may not be accurate depending on platform.
    pub fn is_timeout(&self) -> bool {
        self.as_io_error().is_some_and(|err| {
            matches!(
                err.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            )
        })
    }

    /// Returns true if error was caused by a dropped connection.
    pub fn is_connection_dropped(&self) -> bool {
        match self.repr {
            ErrorRepr::General(kind, _, _) => kind == ErrorKind::Io,
            ErrorRepr::Internal { .. } => self.as_io_error().is_some_and(|err| {
                matches!(
                    err.kind(),
                    io::ErrorKind::BrokenPipe
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::ConnectionRefused
                        | io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::UnexpectedEof
                        | io::ErrorKind::NotConnected
                        | io::ErrorKind::NotFound
                )
            }),

            _ => false,
        }
    }

    /// Returns true if the error is likely to not be recoverable, and the connection must be replaced.
    pub fn is_unrecoverable_error(&self) -> bool {
        let retry_method = self.retry_method();
        match retry_method {
            RetryMethod::Reconnect | RetryMethod::ReconnectFromInitialConnections => true,

            RetryMethod::NoRetry
            | RetryMethod::RetryImmediately
            | RetryMethod::WaitAndRetry
            | RetryMethod::AskRedirect
            | RetryMethod::MovedRedirect
            | RetryMethod::RefreshSlotsAndRetry => false,
        }
    }

    /// Returns the node the error refers to.
    ///
    /// This returns `(addr, slot_id)`.
    pub fn redirect_node(&self) -> Option<(&str, u16)> {
        if !matches!(
            self.kind(),
            ErrorKind::Server(ServerErrorKind::Ask) | ErrorKind::Server(ServerErrorKind::Moved),
        ) {
            return None;
        }
        let mut iter = self.detail()?.split_ascii_whitespace();
        let slot_id: u16 = iter.next()?.parse().ok()?;
        let addr = iter.next()?;
        Some((addr, slot_id))
    }

    /// Specifies what method (if any) should be used to retry this request.
    ///
    /// If you are using the cluster api retrying of requests is already handled by the library.
    ///
    /// This isn't precise, and internally the library uses multiple other considerations rather
    /// than just the error kind on when to retry.
    pub fn retry_method(&self) -> RetryMethod {
        match self.kind() {
            ErrorKind::Server(server_error) => server_error.retry_method(),

            ErrorKind::MasterNameNotFoundBySentinel => RetryMethod::WaitAndRetry,
            ErrorKind::NoValidReplicasFoundBySentinel => RetryMethod::WaitAndRetry,

            ErrorKind::Extension => RetryMethod::NoRetry,
            ErrorKind::UnexpectedReturnType => RetryMethod::NoRetry,
            ErrorKind::InvalidClientConfig => RetryMethod::NoRetry,
            ErrorKind::Client => RetryMethod::NoRetry,
            ErrorKind::EmptySentinelList => RetryMethod::NoRetry,
            #[cfg(feature = "json")]
            ErrorKind::Serialize => RetryMethod::NoRetry,
            ErrorKind::RESP3NotSupported => RetryMethod::NoRetry,

            ErrorKind::Parse => RetryMethod::Reconnect,
            ErrorKind::AuthenticationFailed => RetryMethod::Reconnect,
            ErrorKind::ClusterConnectionNotFound => RetryMethod::ReconnectFromInitialConnections,

            ErrorKind::Io => {
                if self.is_connection_dropped() {
                    RetryMethod::Reconnect
                } else {
                    self.as_io_error()
                        .map(|err| match err.kind() {
                            io::ErrorKind::PermissionDenied | io::ErrorKind::Unsupported => {
                                RetryMethod::NoRetry
                            }

                            _ => RetryMethod::RetryImmediately,
                        })
                        .unwrap_or(RetryMethod::NoRetry)
                }
            }
        }
    }

    /// Returns the internal server errors, if there are any, and the failing commands indices.
    ///
    /// If this is called over over a pipeline or transaction error, the indices correspond to the positions of the failing commands in the pipeline or transaction.
    /// If the error is not a pipeline error, the index will be 0.
    pub fn into_server_errors(self) -> Option<Arc<[(usize, ServerError)]>> {
        match self.repr {
            ErrorRepr::Pipeline(items) => Some(items),
            ErrorRepr::TransactionAborted(errs) => Some(errs),
            ErrorRepr::Server(err) => Some(Arc::from([(0, err)])),
            _ => None,
        }
    }

    pub(crate) fn pipeline(errors: Vec<(usize, ServerError)>) -> Self {
        Self {
            repr: ErrorRepr::Pipeline(Arc::from(errors)),
        }
    }

    pub(crate) fn make_aborted_transaction(errs: Vec<(usize, ServerError)>) -> Self {
        Self {
            repr: ErrorRepr::TransactionAborted(Arc::from(errs)),
        }
    }

    pub(crate) fn make_empty_command() -> Self {
        Self {
            repr: ErrorRepr::General(ErrorKind::Client, "empty command", None),
        }
    }
}

/// Creates a new Redis error with the `Extension` kind.
///
/// This function is used to create Redis errors for extension error codes
/// that are not directly understood by the library.
///
/// # Arguments
///
/// * `code` - The error code string returned by the Redis server
/// * `detail` - Optional detailed error message. If None, a default message is used.
///
/// # Returns
///
/// A `RedisError` with the `Extension` kind.
pub fn make_extension_error(code: String, detail: Option<String>) -> RedisError {
    RedisError {
        repr: ErrorRepr::Server(ServerError(crate::errors::Repr::Extension {
            code: code.into(),
            detail: detail.map(|detail| detail.into()),
        })),
    }
}

#[cfg(feature = "tls-native-tls")]
impl From<native_tls::Error> for RedisError {
    fn from(err: native_tls::Error) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Client,
                err: Arc::new(err),
            },
        }
    }
}

#[cfg(feature = "tls-rustls")]
impl From<rustls::Error> for RedisError {
    fn from(err: rustls::Error) -> Self {
        Self {
            repr: ErrorRepr::Internal {
                kind: ErrorKind::Client,
                err: Arc::new(err),
            },
        }
    }
}

impl From<ServerError> for RedisError {
    fn from(err: ServerError) -> Self {
        Self {
            repr: ErrorRepr::Server(err),
        }
    }
}

impl From<ServerErrorKind> for ErrorKind {
    fn from(kind: ServerErrorKind) -> Self {
        Self::Server(kind)
    }
}

impl From<ParsingError> for RedisError {
    fn from(err: ParsingError) -> Self {
        Self {
            repr: ErrorRepr::Parsing(err),
        }
    }
}

impl TryFrom<RedisError> for ServerError {
    type Error = RedisError;

    fn try_from(err: RedisError) -> Result<Self, RedisError> {
        match err.repr {
            ErrorRepr::Server(err) => Ok(err),
            _ => Err(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::parse_redis_value;

    #[test]
    fn test_redirect_node() {
        let err = parse_redis_value(b"-ASK 123 foobar:6380\r\n")
            .unwrap()
            .extract_error()
            .unwrap_err();
        let node = err.redirect_node();

        assert_eq!(node, Some(("foobar:6380", 123)));
    }
}
