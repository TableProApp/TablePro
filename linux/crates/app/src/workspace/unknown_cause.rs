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

/// The causes the user is told apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Wording {
    Stopped,
    Internal,
    ConnectionLost,
}

impl UnknownCause {
    /// What happened to `tabs`, the tab names already joined.
    pub fn sentence(&self, tabs: &str) -> String {
        match self.wording() {
            Wording::Stopped => crate::i18n::gettext_f(
                "Saving {tabs} was stopped before the database confirmed it. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
            Wording::Internal => crate::i18n::gettext_f(
                "TablePro hit an internal error while saving {tabs}. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
            Wording::ConnectionLost => crate::i18n::gettext_f(
                "The connection was lost while saving {tabs}. The changes may already be in the database.",
                &[("tabs", tabs)],
            ),
        }
    }

    /// Whether the user is told the same thing about both.
    pub fn reads_as(&self, other: &Self) -> bool {
        self.wording() == other.wording()
    }

    fn wording(&self) -> Wording {
        match self {
            Self::Interrupted => Wording::Stopped,
            Self::Panicked => Wording::Internal,
            Self::CommitAckLost { .. } | Self::PartiallyApplied | Self::Closed => Wording::ConnectionLost,
        }
    }
}
