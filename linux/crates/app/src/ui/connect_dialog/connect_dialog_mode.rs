use tablepro_storage::SavedConnection;

/// What the connect dialog is opened for.
#[derive(Debug, Clone, Default)]
pub enum ConnectDialogMode {
    /// Connect, and save the connection once the connect works.
    #[default]
    Create,
    /// Change a saved connection without connecting to it. Its secrets
    /// stay in the keyring, and an empty password row keeps them.
    Edit(Box<SavedConnection>),
}

impl ConnectDialogMode {
    /// The saved connection an Edit changes.
    pub fn editing(&self) -> Option<&SavedConnection> {
        match self {
            Self::Create => None,
            Self::Edit(saved) => Some(saved),
        }
    }
}
