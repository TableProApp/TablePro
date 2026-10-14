/// What changes where the tab's save stands: Save, Discard, Stop Saving
/// and how the window's save of the tab went.
#[derive(Debug)]
pub(crate) enum SaveInput {
    Save,
    /// The window started saving the tab's pending structure.
    SaveStarted,
    StopSaving,
    Discard,
    /// Read the table again and drop the draft, for a save whose outcome
    /// nobody knows.
    Reload,
    SaveCompleted {
        new_table_name: Option<String>,
    },
    SaveFailed(String),
    /// The save found the table changed since the tab read it, and left
    /// it as it was.
    TableChangedBeforeSave,
    /// The save may have landed; the tracker refuses to save again until
    /// the table is read again or the draft is discarded.
    SaveOutcomeUnknown(String),
}
