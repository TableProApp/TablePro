use tablepro_session::{ConnectIntent, ConnectSource, SessionKey};
use tablepro_storage::SavedConnection;

use crate::ui::ConnectFailure;

/// What a new window opens on.
#[derive(Debug)]
pub enum WindowLaunch {
    Picker,
    Connect(Box<SavedConnection>),
    /// A database file, from the file manager or the command line.
    OpenFile(gio::File),
    /// The sessions one window held when the application last quit, in
    /// the order it adopted them.
    Restore(Vec<SessionKey>),
    /// A connection from the connect dialog that another window could
    /// not ask its question for, connected here from the start.
    ConnectIntent(Box<ConnectIntent>),
    /// A connect that failed beside another window's sessions, shown on
    /// the failed page with its remedies, without connecting again.
    ConnectFailed {
        source: Box<ConnectSource>,
        failure: Box<ConnectFailure>,
    },
}
