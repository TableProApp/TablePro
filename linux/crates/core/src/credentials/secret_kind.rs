/// Which secret of a connection this is.
///
/// The keyring stores one item per (connection, kind), so deleting a
/// connection removes all three and a password change never disturbs an
/// SSH passphrase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecretKind {
    DatabasePassword,
    SshPassword,
    SshPassphrase,
}

impl SecretKind {
    pub const ALL: [SecretKind; 3] = [
        SecretKind::DatabasePassword,
        SecretKind::SshPassword,
        SecretKind::SshPassphrase,
    ];

    /// The `kind` attribute the keyring item carries. Stable: changing
    /// one of these strings orphans every secret already stored.
    pub fn attribute(self) -> &'static str {
        match self {
            Self::DatabasePassword => "db_password",
            Self::SshPassword => "ssh_password",
            Self::SshPassphrase => "ssh_passphrase",
        }
    }
}
