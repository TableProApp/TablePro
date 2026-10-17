use super::{SaveId, SaveRejection};

/// What asking a tab to save did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveStart {
    Started(SaveId),
    /// Written at once, with nothing left running: an editor tab's file.
    Saved,
    NothingToSave,
    Rejected(SaveRejection),
}
