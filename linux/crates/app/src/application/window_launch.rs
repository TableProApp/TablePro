use tablepro_session::SessionKey;
use tablepro_storage::SavedConnection;

/// What a new window opens on.
#[derive(Debug, Clone)]
pub enum WindowLaunch {
    Picker,
    Connect(Box<SavedConnection>),
    /// A database file, from the file manager or the command line.
    OpenFile(gio::File),
    /// A session that was open when the application last quit.
    Restore(SessionKey),
}
