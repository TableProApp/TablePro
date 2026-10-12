use tablepro_core::credentials::{SecretKind, SecretSave};
use tablepro_storage::SavedConnection;

/// A connection entry and its secrets, written once the connect works.
#[derive(Debug, Clone)]
pub struct PendingSave {
    pub connection: SavedConnection,
    pub secrets: Vec<SecretSave>,
    /// Secrets an earlier save of this entry may hold that the user
    /// asked not to keep, so the next connect asks for them instead.
    pub forget: Vec<SecretKind>,
    /// A new entry's secrets are removed again when its list write
    /// fails; an existing entry's secrets still belong to it.
    pub is_new: bool,
}
