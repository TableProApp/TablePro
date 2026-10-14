use tablepro_storage::{ConnectionColor, SavedConnection};
use uuid::Uuid;

use super::resolve_file_identity::ResolvedFile;
use super::session_window_command::SessionWindowCommand;
use super::sqlite_location_dialog::LocationChoice;
use crate::ui::connect_dialog::ConnectSubmission;
use crate::workspace::CloseReason;

#[derive(Debug)]
pub(crate) enum SessionWindowInput {
    /// Open a saved connection: in this window from the picker, in
    /// another one otherwise.
    OpenSaved(Box<SavedConnection>),
    /// Open a database file, as the file manager or the command line
    /// hands it over.
    OpenFile(gio::File),
    /// The file resolved, off the GTK thread, to the session it opens.
    FileResolved(Box<ResolvedFile>),
    OpenConnectDialog,
    /// The connect dialog's Connect: connect, then save the entry.
    ConnectFromDialog(Box<ConnectSubmission>),
    DialogClosed,
    /// Stop the connect in progress, or leave a failed one, for the
    /// picker.
    CancelConnect,
    /// Connect again from where the failed connect came from, reading
    /// the keyring again.
    RetryConnect,
    /// Open the connect dialog on a connection that failed to connect,
    /// with the focus on the setting that fixes it.
    EditConnection,
    /// Close the workspace through its prompts and return to the
    /// picker.
    Disconnect,
    /// The prompts approved the disconnect.
    TeardownApproved,
    /// Close the workspace's current tab, or the window when it shows
    /// no tab.
    CloseCurrent,
    /// The health banner's Retry: ask the session to reconnect now.
    Reconnect,
    /// The toast's Reset: move the workspace's unreadable saved tabs
    /// aside.
    ResetWorkspaceLayout,
    /// The application asks the window to close.
    CloseRequested(CloseReason),
    /// The workspace gained or lost something a logout would lose.
    DirtyChanged(bool),
    /// The number of saves running in the workspace changed.
    SavesInFlightChanged(usize),
    TitleChanged(String),
    Command(Box<SessionWindowCommand>),
    /// The answer for a file on a filesystem whose locking SQLite cannot
    /// trust, or ReadWrite when there was nothing to ask.
    LocationChosen {
        generation: tablepro_session::connect::AttemptGeneration,
        choice: LocationChoice,
    },
    /// The user found the file a saved connection lost.
    FileLocated(std::path::PathBuf),
    /// The located file's path is saved; connect to it.
    LocatedSaved(Box<SavedConnection>),
    ReloadConnections,
    ConnectionsLoaded(Vec<SavedConnection>),
    ConnectionListUnavailable,
    ResetConnectionList,
    SecretDeleteFailed(Uuid),
    DeleteConnection(Uuid),
    DuplicateConnection(Box<SavedConnection>),
    /// A colour picked from a connection row's menu, or `None` when the
    /// user cleared it.
    SetConnectionColor(Uuid, Option<ConnectionColor>),
    /// A group picked from a connection row's menu, or `None` when the
    /// user took it out of one.
    SetConnectionGroup(Uuid, Option<String>),
    ExportConnections,
    ImportConnections,
    /// The file the user picked to import, read off the GTK thread.
    ConnectionsFileRead {
        path: std::path::PathBuf,
        bytes: Vec<u8>,
    },
    ShowToast(String),
}
