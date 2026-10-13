use uuid::Uuid;

use super::SaveSettled;

/// What the workspace did that its tabs have to show.
#[derive(Debug, Clone)]
pub enum WorkspaceEvent {
    SaveStarted {
        tab: Uuid,
    },
    SaveSettled(Box<SaveSettled>),
    /// The tabs' pending changes were dropped. `reload` asks each to read
    /// its table again, for a save whose outcome nobody knew.
    Discarded {
        tabs: Vec<Uuid>,
        reload: bool,
    },
}
