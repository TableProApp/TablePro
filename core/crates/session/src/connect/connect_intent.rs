use super::{ConnectRequest, PendingSave};
use crate::registry::SessionKey;

/// A connect the user asked for from the connect dialog: where to go,
/// which session it is, and what to save once it works.
#[derive(Debug)]
pub struct ConnectIntent {
    pub key: SessionKey,
    pub request: ConnectRequest,
    /// `None` when the user connected without saving.
    pub pending_save: Option<PendingSave>,
}
