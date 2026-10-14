use futures::channel::oneshot;

use super::CloseDecision;

/// Why a window is asked to close, and who hears how it ended.
#[derive(Debug)]
pub enum CloseReason {
    /// The application is quitting. A dropped sender means the window
    /// went without deciding.
    Quit(oneshot::Sender<CloseDecision>),
}
