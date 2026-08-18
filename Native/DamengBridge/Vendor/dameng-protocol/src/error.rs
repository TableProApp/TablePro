//! Error types for the Dameng protocol.

use std::fmt;

/// Errors that can occur when parsing or building Dameng protocol messages.
#[derive(Debug)]
pub enum Error {
    /// Not enough bytes to parse a frame or message.
    Incomplete,
    /// Checksum mismatch in frame header.
    ChecksumMismatch,
    /// Invalid frame header (bad length, unknown version, etc.).
    InvalidFrame(String),
    /// Unknown message type.
    UnknownMessageType(u8),
    /// Failed to decode a string value.
    DecodeError(String),
    /// I/O error during read/write.
    Io(std::io::Error),
    /// Authentication failed.
    AuthFailed(String),
    /// Server returned an error message.
    ServerError(i32, String),
    /// LOB streaming operation failed (e.g. stream ended prematurely or invalid chunk).
    LobStreamError(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Incomplete => write!(f, "incomplete protocol data"),
            Error::ChecksumMismatch => write!(f, "checksum mismatch"),
            Error::InvalidFrame(s) => write!(f, "invalid frame: {s}"),
            Error::UnknownMessageType(t) => write!(f, "unknown message type: {t}"),
            Error::DecodeError(s) => write!(f, "decode error: {s}"),
            Error::Io(e) => write!(f, "IO error: {e}"),
            Error::AuthFailed(s) => write!(f, "auth failed: {s}"),
            Error::ServerError(code, msg) => write!(f, "server error {code}: {msg}"),
            Error::LobStreamError(s) => write!(f, "LOB stream error: {s}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

/// Result type alias for protocol operations.
pub type Result<T> = std::result::Result<T, Error>;
