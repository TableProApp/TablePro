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
}
