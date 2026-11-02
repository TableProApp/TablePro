use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ClaimError {
    /// Another window has this session; the caller shows that window.
    #[error("the connection is already open in another window")]
    AlreadyOpen { window_id: u32 },
}

impl ClaimError {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::AlreadyOpen { .. } => "claim.already_open",
        }
    }
}
