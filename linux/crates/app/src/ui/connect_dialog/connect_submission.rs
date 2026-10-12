use tablepro_session::{ConnectRequest, PendingSave};

/// What the connect dialog hands the window: where to connect, and
/// what to save once it works. The dialog itself never connects.
#[derive(Debug, Clone, glib::Boxed)]
#[boxed_type(name = "TableProConnectSubmission")]
pub struct ConnectSubmission {
    pub request: ConnectRequest,
    pub pending_save: PendingSave,
}
