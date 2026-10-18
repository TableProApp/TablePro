use thiserror::Error;

/// Why a value could not be written into SQL as a literal.
///
/// Only engines without parameters take this path, so the failure is
/// about the text form rather than about a wire type.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LiteralError {
    #[error("{found} has no literal form in this dialect")]
    Unrepresentable { found: &'static str },
    #[error("this value could not be read from the server, so it cannot be written back: {reason}")]
    Undecodable { reason: String },
}
