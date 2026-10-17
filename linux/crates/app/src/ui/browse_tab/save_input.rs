use crate::services::change_origins::ChangeOrigins;
use crate::services::change_tracker::{RowKey, StatementSource};

/// What changes where the tab's save stands: Save, Discard, Stop Saving
/// and how the window's save of the tab went.
#[derive(Debug)]
pub(crate) enum SaveInput {
    CommitSave,
    /// The window started saving the tab's changes.
    SaveStarted,
    StopSaving,
    /// Discard clicked: ask before the changes go.
    ConfirmDiscard,
    DiscardAll,
    DiscardAndRefresh,
    /// The save landed, adding and removing these rows. Edits made
    /// while it ran stay pending.
    SaveCommitted(ChangeOrigins),
    /// The pending changes stay, so the user can fix the cause and
    /// save again.
    SaveFailed(String),
    /// The save may have landed. The changes stay, and the tracker
    /// refuses to save them again until the table is read again.
    SaveOutcomeUnknown(String),
    FlashErrorRow(StatementSource),
    /// The flash on a failed statement's row ran its course.
    ErrorFlashEnded(RowKey),
}
