use gtk4::glib;
use libadwaita as adw;
use tablepro_core::SafeModeLevel;
use tablepro_core::credentials::SecretKind;
use tablepro_session::SessionKey;
use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionTag, ConnectionTagName, SavedConnection};
use uuid::Uuid;

use super::connect_failure_details::Remedy;
use super::file_location_dialog::LocationChoice;
use super::resolve_file_identity::ResolvedFile;
use super::session_window_command::SessionWindowCommand;
use crate::services::connection_deletion::DeletionOptions;
use crate::ui::connect_dialog::ConnectSubmission;
use crate::workspace::{CloseReason, CompletedWork};

#[derive(Debug)]
pub(crate) enum SessionWindowInput {
    /// Open a saved connection, beside the sessions the window holds.
    OpenSaved(Box<SavedConnection>),
    /// Open a database file, as the file manager or the command line
    /// hands it over.
    OpenFile(gio::File),
    /// The file resolved, off the GTK thread, to the session it opens.
    FileResolved(Box<ResolvedFile>),
    /// Open one of the sessions the window was opened to restore.
    Restore(SessionKey),
    /// The saved connections could not be read for this restored key,
    /// which stays recorded for a launch that can read them.
    RestoreUnread(SessionKey),
    /// The restored saved connection as the list holds it now, or `None`
    /// once it is deleted.
    RestoreSaved {
        id: Uuid,
        saved: Option<Box<SavedConnection>>,
    },
    OpenConnectDialog,
    /// The connect dialog's Connect: connect, then save the entry.
    ConnectFromDialog(Box<ConnectSubmission>),
    DialogClosed,
    /// The connecting page's Cancel, which stops every connect, or the
    /// failed page's Choose Connection.
    CancelConnect,
    /// Stop the connect running for the key.
    StopConnecting(SessionKey),
    /// The failed page's Retry: connect again from where the failed
    /// connect came from, reading the keyring again.
    RetryConnect,
    /// The failed page's Enter Password: connect again, asking for this
    /// secret instead of reading the keyring's copy.
    RetryWithNewSecret(SecretKind),
    /// The failed page's Edit Connection, with the focus on the setting
    /// that fixes the failure.
    EditConnection,
    /// The way on a failed connect's Details offered for the key.
    Remedy {
        key: SessionKey,
        remedy: Remedy,
    },
    /// Say why the last connect for the key failed, and offer its way on.
    ShowConnectFailure(SessionKey),
    /// Let go of a failed connect the tree keeps a row for.
    ForgetConnectFailure(SessionKey),
    /// Open the connect dialog on a saved connection to change it.
    EditSavedConnection(Uuid),
    /// The connect dialog saved its changes to a saved connection.
    ConnectionSaved(Uuid),
    /// Close the session in front through its prompts.
    Disconnect,
    /// Close the session open under the key through its prompts.
    DisconnectSession(SessionKey),
    /// Open Database… on a connection's row: pick another of its server's
    /// databases to open beside it.
    ChooseDatabaseIn(SessionKey),
    /// The prompts approved closing the session under the key.
    SessionTeardownApproved(SessionKey),
    /// Bring the session under the key to the front.
    ShowSession(SessionKey),
    /// Open a SQL editor tab in the session under the key.
    NewQueryIn(SessionKey),
    /// Read the catalog of the session under the key again.
    RefreshIn(SessionKey),
    /// Another session came to the front of the shell.
    FrontChanged,
    /// A tab of another window's session was dropped on this window's
    /// tab bar. Weak and sendable, since the window's input also
    /// crosses to the runtime.
    ReturnForeignTab(glib::SendWeakRef<adw::TabPage>),
    /// The main menu's Safe Mode level for the session that was in front
    /// when the user picked it.
    SetSafeMode {
        key: SessionKey,
        level: SafeModeLevel,
    },
    /// The prompts approved connecting the saved connection again at the
    /// level it was just given.
    ReopenApproved(Uuid),
    /// Close the current tab, or the window when it shows no tab.
    CloseCurrent,
    /// The health banner's Retry: ask the session to reconnect now.
    Reconnect,
    /// The toast's Reset: move the workspace's unreadable saved tabs
    /// aside.
    ResetWorkspaceLayout,
    /// The application asks the window to close.
    CloseRequested(CloseReason),
    /// A session gained or lost something a logout would lose.
    DirtyChanged,
    /// The number of saves running in a session changed.
    SavesInFlightChanged,
    /// A run, save or export ended in one of the workspace's tabs.
    WorkCompleted(CompletedWork),
    /// The tab in front, the open tabs or the window's focus changed.
    TabsChanged,
    /// A notification about the tab was clicked.
    FocusTab(Uuid),
    Command(Box<SessionWindowCommand>),
    /// The answer for the file of connect `id` on a filesystem whose
    /// locking the engines cannot trust, or ReadWrite when there was
    /// nothing to ask.
    LocationChosen {
        id: u64,
        choice: LocationChoice,
    },
    /// The user found the file the saved connection `id` lost.
    FileLocated {
        id: Uuid,
        path: std::path::PathBuf,
    },
    /// The located file's path is saved; connect to it.
    LocatedSaved(Box<SavedConnection>),
    /// Read the connection list, which every picker follows from then on.
    LoadConnections,
    ResetConnectionList,
    /// The keyring kept a deleted connection's secrets, so the entry
    /// was kept too. The toast's Retry runs the same delete again.
    SecretDeleteFailed(Uuid, DeletionOptions),
    /// Ask whether to delete a saved connection.
    DeleteConnection(Uuid),
    /// The user confirmed the delete.
    ConfirmDelete(Uuid, DeletionOptions),
    DuplicateConnection(Uuid),
    /// A colour picked from a connection row's menu, or `None` when the
    /// user cleared it.
    SetConnectionColor(Uuid, Option<ConnectionColor>),
    /// A group picked from a connection row's menu, or `None` when the
    /// user took it out of one.
    SetConnectionGroup(Uuid, Option<ConnectionGroupName>),
    /// A tag ticked on or off in a connection row's menu.
    SetConnectionTag(Uuid, Uuid, bool),
    /// A new tag, put on the connection `on` when there is one.
    CreateTag {
        name: ConnectionTagName,
        color: ConnectionColor,
        on: Option<Uuid>,
    },
    /// A tag renamed or recoloured in Manage Tags.
    UpdateTag(ConnectionTag),
    DeleteTag(Uuid),
    ManageTags,
    ExportConnections,
    ImportConnections,
    /// The file the user picked to import, read off the GTK thread.
    ConnectionsFileRead {
        path: std::path::PathBuf,
        bytes: Vec<u8>,
    },
    ShowToast(String),
}
