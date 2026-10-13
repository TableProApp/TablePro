use tablepro_core::CommitToken;

/// Why nobody knows whether a save landed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnknownCause {
    /// The commit was sent and its answer never came. The token, where
    /// the engine gives one, is what asks the server afterwards.
    CommitAckLost {
        token: Option<CommitToken>,
    },
    /// Some statements landed on an engine that cannot undo them.
    PartiallyApplied,
    /// The save was stopped, or timed out or lost its connection, before
    /// the server confirmed it.
    Interrupted,
    Panicked,
    /// The session closed under the save.
    Closed,
}

impl UnknownCause {
    /// What happened to `tabs`, the tab names already joined.
    pub fn sentence(&self, tabs: &str) -> String {
        match self {
            Self::Interrupted => crate::i18n::gettext_f(
                "Saving {tabs} was stopped before the database confirmed it. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
            Self::Panicked => crate::i18n::gettext_f(
                "TablePro hit an internal error while saving {tabs}. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
            Self::CommitAckLost { .. } | Self::PartiallyApplied | Self::Closed => crate::i18n::gettext_f(
                "The connection was lost while saving {tabs}. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
        }
    }
}
