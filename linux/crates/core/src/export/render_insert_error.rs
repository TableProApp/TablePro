use thiserror::Error;

use crate::dialect::LiteralError;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RenderInsertError {
    #[error(transparent)]
    Literal(#[from] LiteralError),
    /// Every column is left to the server, and the engine has no
    /// spelling for a row with no values.
    #[error("there is nothing to insert")]
    NoValues,
}
