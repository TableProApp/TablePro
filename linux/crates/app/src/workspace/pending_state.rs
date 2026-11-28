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

// The row tracker lives in the core and reports a coded state (ADR
// 0068); the app words the unknown cause.
impl From<tablepro_core::edits::PendingState> for PendingState {
    fn from(state: tablepro_core::edits::PendingState) -> Self {
        use tablepro_core::edits::PendingState as Core;
        match state {
            Core::Clean => Self::Clean,
            Core::Unsaved => Self::Unsaved,
            Core::Saving => Self::Saving,
            Core::OutcomeUnknown(cause) => Self::OutcomeUnknown(cause.into()),
        }
    }
}
