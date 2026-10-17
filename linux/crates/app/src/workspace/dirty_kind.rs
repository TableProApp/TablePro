use super::UnknownCause;

/// What closing a tab would lose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DirtyKind {
    Unsaved,
    /// A save that may have landed, which the user has to look at.
    OutcomeUnknown(UnknownCause),
    /// An editor tab's transaction, which the server rolls back when its
    /// connection ends.
    OpenTransaction,
    /// An editor tab's text differs from its file. Closing the window
    /// keeps the text with the tab's other drafts, so only closing the
    /// tab loses it.
    UnsavedFile,
}

impl DirtyKind {
    /// Whether closing the whole window loses it too, which a logout
    /// would.
    pub fn lost_with_the_window(&self) -> bool {
        !matches!(self, Self::UnsavedFile)
    }
}
