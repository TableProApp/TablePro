use tablepro_core::credentials::SecretKind;
use tablepro_storage::{SavedConnection, SavedSshAuth};

use super::secret_change::SecretChange;

/// What an edit does to each secret a saved connection can keep.
#[derive(Debug, Clone, Default)]
pub struct SecretChanges {
    pub database_password: SecretChange,
    pub ssh_password: SecretChange,
    pub ssh_passphrase: SecretChange,
}

impl SecretChanges {
    pub fn get(&self, kind: SecretKind) -> &SecretChange {
        match kind {
            SecretKind::DatabasePassword => &self.database_password,
            SecretKind::SshPassword => &self.ssh_password,
            SecretKind::SshPassphrase => &self.ssh_passphrase,
        }
    }

    /// Record on `connection` whether its key's passphrase is in the
    /// keyring once the edit is saved. The form only knows what was
    /// typed, and an empty passphrase row keeps the one `original` had.
    pub fn settle_passphrase(&self, connection: &mut SavedConnection, original: &SavedConnection) {
        let Some(SavedSshAuth::PrivateKey { has_passphrase, .. }) = connection.ssh.as_mut().map(|ssh| &mut ssh.auth)
        else {
            return;
        };
        *has_passphrase = match &self.ssh_passphrase {
            SecretChange::Replace(_) => true,
            SecretChange::Remove => false,
            SecretChange::Keep => original.has_stored_passphrase(),
        };
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use secrecy::SecretString;
    use tablepro_core::{AuthMode, TlsConfig};
    use tablepro_storage::SavedSshConfig;
    use uuid::Uuid;

    use super::*;

    fn keyed(has_passphrase: bool) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: Some(SavedSshConfig {
                host: "bastion".to_owned(),
                port: None,
                username: None,
                jump_hosts: Vec::new(),
                auth: SavedSshAuth::PrivateKey {
                    path: Some(PathBuf::from("/home/u/.ssh/id_ed25519")),
                    has_passphrase,
                },
            }),
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    #[test]
    fn an_empty_passphrase_row_keeps_the_stored_passphrase() {
        let original = keyed(true);
        let mut edited = keyed(false);

        SecretChanges::default().settle_passphrase(&mut edited, &original);

        assert!(edited.has_stored_passphrase());
    }

    #[test]
    fn a_typed_or_removed_passphrase_says_so() {
        let mut edited = keyed(false);
        let typed = SecretChanges {
            ssh_passphrase: SecretChange::Replace(SecretString::from("phrase")),
            ..SecretChanges::default()
        };
        typed.settle_passphrase(&mut edited, &keyed(false));
        assert!(edited.has_stored_passphrase());

        let removed = SecretChanges {
            ssh_passphrase: SecretChange::Remove,
            ..SecretChanges::default()
        };
        removed.settle_passphrase(&mut edited, &keyed(true));
        assert!(!edited.has_stored_passphrase());
    }
}
