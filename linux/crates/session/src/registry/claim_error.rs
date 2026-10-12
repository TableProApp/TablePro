use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ClaimError {
    /// Another window has this session; the caller shows that window.
    #[error("the connection is already open in another window")]
    AlreadyOpen { window_id: u32 },
}
