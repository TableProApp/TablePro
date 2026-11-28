use crate::CommitToken;

use super::touch::Touch;

/// Where a save's edits end: every edit touched before this one is in
/// the save, and an edit touched at or after it was made while the save
/// ran, so a commit leaves it pending.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SaveSnapshot(pub Touch);

impl SaveSnapshot {
    pub fn includes(self, touched: Touch) -> bool {
        touched < self.0
    }
}

/// Why nobody knows whether a save landed. Each app words the cause; the
/// core carries only the code and the fields that word it.
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
    /// Stable code an app words.
    pub fn code(&self) -> &'static str {
        match self {
            Self::CommitAckLost { .. } => "edit.outcome_unknown.commit_ack_lost",
            Self::PartiallyApplied => "edit.outcome_unknown.partially_applied",
            Self::Interrupted => "edit.outcome_unknown.interrupted",
            Self::Panicked => "edit.outcome_unknown.panicked",
            Self::Closed => "edit.outcome_unknown.closed",
        }
    }
}

/// What a save left in the database, which decides what its tracker does
/// next. An app classifies its driver result into this; the tracker
/// reads only the outcome and, when unknown, its cause.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveOutcome {
    /// Every statement landed. `rows` is the total the server reported,
    /// when every statement reported one.
    Committed { rows: Option<u64> },
    /// Nothing landed.
    RolledBack,
    /// It may have landed, and only the server can say.
    Unknown(UnknownCause),
}

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

/// Why the tracker refused to start a save. Nothing was sent. An app
/// words it; a row save and a structure save share the wording.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackerRejection {
    /// The last save's outcome is unknown, and saving again could apply
    /// the same changes twice.
    OutcomeUnknown,
    AlreadySaving,
    /// The tab has not read the table's columns, which a row save is
    /// planned against.
    ColumnsNotRead,
    /// The row changes cannot be written as SQL.
    Build(crate::dml::BuildSqlError),
    /// Edits made before the table's columns changed are for these
    /// columns, which are gone or no longer take them.
    ColumnsChanged(Vec<String>),
    /// Edits made before the table's primary key changed name their
    /// rows by the old one.
    KeyChanged,
}

impl TrackerRejection {
    /// Stable code an app words.
    pub fn code(&self) -> &'static str {
        match self {
            Self::OutcomeUnknown => "edit.reject.outcome_unknown",
            Self::AlreadySaving => "edit.reject.already_saving",
            Self::ColumnsNotRead => "edit.reject.columns_not_read",
            Self::Build(_) => "edit.reject.build",
            Self::ColumnsChanged(_) => "edit.reject.columns_changed",
            Self::KeyChanged => "edit.reject.key_changed",
        }
    }
}
