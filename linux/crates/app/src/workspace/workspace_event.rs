use uuid::Uuid;

use super::SaveSettled;

/// What the workspace did that its tabs have to show.
#[derive(Debug, Clone)]
pub enum WorkspaceEvent {
    SaveStarted {
        tab: Uuid,
    },
    SaveSettled {
        settled: Box<SaveSettled>,
        /// A close prompt covering the tab was deciding as the save
        /// settled, and says itself how it went.
        in_prompt: bool,
    },
    /// The tabs' pending changes were dropped. `reload` asks each to read
    /// its table again, for a save whose outcome nobody knew.
    Discarded {
        tabs: Vec<Uuid>,
        reload: bool,
    },
}
