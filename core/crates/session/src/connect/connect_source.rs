use tablepro_storage::SavedConnection;

use super::ConnectIntent;
use crate::registry::FileIdentity;

/// Where a window's connect came from, kept so Retry repeats it.
#[derive(Debug)]
pub enum ConnectSource {
    Saved(Box<SavedConnection>),
    Intent(Box<ConnectIntent>),
    File(FileIdentity),
}
