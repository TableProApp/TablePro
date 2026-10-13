use super::{SaveId, SaveRejection};

/// What asking a tab to save did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveStart {
    Started(SaveId),
    NothingToSave,
    Rejected(SaveRejection),
}
