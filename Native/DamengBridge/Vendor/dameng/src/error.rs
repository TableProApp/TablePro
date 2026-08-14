//! Error types for the Dameng driver.

use std::fmt;

#[derive(Debug)]
pub enum Error {
    Protocol(dameng_protocol::Error),
    Io(std::io::Error),
    ConnectionFailed(String),
    AuthFailed(String),
    ServerError(i32, String),
    DecodeError(String),
    QueryFailed(String),
    NotConnected,
    ConfigError(String),
    /// Invalid transaction isolation level was specified.
    InvalidIsolation(String),
    /// LOB locator has been freed and can no longer be used.
    LobFreed(String),
    /// Date/time format parsing failed.
    InvalidDateFormat(String),
    /// Server returned a busy or overloaded state.
    ServerBusy,
    /// LOB read operation failed.
    LobReadFailed(String),
    /// LOB write operation failed.
    LobWriteFailed(String),
    /// Operation timed out.
    Timeout(String),
    /// Schema/database name resolution error.
    SchemaError(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Protocol(e) => write!(f, "protocol error: {e}"),
            Error::Io(e) => write!(f, "IO error: {e}"),
            Error::ConnectionFailed(s) => write!(f, "connection failed: {s}"),
            Error::AuthFailed(s) => write!(f, "auth failed: {s}"),
            Error::ServerError(code, msg) => write!(f, "server error {code}: {msg}"),
            Error::DecodeError(s) => write!(f, "decode error: {s}"),
            Error::QueryFailed(s) => write!(f, "query failed: {s}"),
            Error::NotConnected => write!(f, "not connected"),
            Error::ConfigError(s) => write!(f, "config error: {s}"),
            Error::InvalidIsolation(s) => write!(f, "invalid isolation level: {s}"),
            Error::LobFreed(s) => write!(f, "LOB freed: {s}"),
            Error::InvalidDateFormat(s) => write!(f, "invalid date format: {s}"),
            Error::ServerBusy => write!(f, "server busy"),
            Error::LobReadFailed(s) => write!(f, "LOB read failed: {s}"),
            Error::LobWriteFailed(s) => write!(f, "LOB write failed: {s}"),
            Error::Timeout(s) => write!(f, "timeout: {s}"),
            Error::SchemaError(s) => write!(f, "schema error: {s}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<dameng_protocol::Error> for Error {
    fn from(e: dameng_protocol::Error) -> Self {
        Error::Protocol(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
