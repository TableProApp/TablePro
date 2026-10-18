use super::UnknownCause;

/// Where a tab's tracker stands with its unsaved changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PendingState {
    Clean,
    Unsaved,
    Saving,
    /// A save may have landed. The tracker refuses to save again until
    /// the tab is reloaded or its changes are discarded.
    OutcomeUnknown(UnknownCause),
}
