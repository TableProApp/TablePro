use tablepro_core::credentials::{SecretError, SecretKind, SecretVault};
use tablepro_storage::{SavedConnection, SavedSshAuth, StorageError};

use super::{ConnectionWrites, PendingSave};

/// What a save kept, and which secrets the keyring refused.
#[derive(Debug)]
pub struct PersistReport {
    pub saved: SavedConnection,
    pub secret_failures: Vec<(SecretKind, SecretError)>,
}

/// Write a connection's secrets, then its entry.
///
/// Secrets go first so the one list write can record whether the
/// passphrase landed. A secret the keyring refuses does not stop the
/// save: the entry is written without it and the failure is reported,
/// so the user keeps the connection and is asked for the secret at the
/// next connect.
pub async fn persist_pending_save(
    secrets: &dyn SecretVault,
    connections: &dyn ConnectionWrites,
    save: PendingSave,
) -> Result<PersistReport, StorageError> {
    let PendingSave {
        connection: mut saved,
        secrets: to_store,
        is_new,
    } = save;
    let mut secret_failures = Vec::new();
    for secret in &to_store {
        let stored = secrets
            .store(saved.id, secret.kind, &secret.secret, &secret.label)
            .await;
        if secret.kind == SecretKind::SshPassphrase {
            record_passphrase(&mut saved, stored.is_ok());
        }
        if let Err(error) = stored {
            tracing::warn!(kind = ?secret.kind, %error, "a secret was not stored");
            secret_failures.push((secret.kind, error));
        }
    }

    if let Err(error) = connections.upsert(saved.clone()).await {
        // The list write is what makes the connection real. Without it a
        // new entry's secrets belong to nothing, so they go again.
        if is_new && let Err(cleanup) = secrets.delete_connection(saved.id).await {
            tracing::warn!(%cleanup, "the secrets of an unsaved connection were left in the keyring");
        }
        return Err(error);
    }
    Ok(PersistReport { saved, secret_failures })
}

fn record_passphrase(saved: &mut SavedConnection, stored: bool) {
    if let Some(ssh) = saved.ssh.as_mut()
        && let SavedSshAuth::PrivateKey { has_passphrase, .. } = &mut ssh.auth
    {
        *has_passphrase = stored;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use futures::future::BoxFuture;
    use secrecy::SecretString;
    use tablepro_core::credentials::SecretSave;
    use tablepro_core::{AuthMode, TlsConfig};
    use tablepro_storage::{ConnectionStore, SavedSshConfig, StoragePaths};
    use tablepro_test_support::{Call, FakeSecretVault};
    use uuid::Uuid;

    use super::*;
    use crate::connect::StoreConnectionWrites;
    use crate::test_support::paused_tasks;

    /// Records each entry write next to how many keyring calls came
    /// before it, so the order is visible.
    struct RecordingWrites {
        vault: Arc<FakeSecretVault>,
        writes: Mutex<Vec<(usize, SavedConnection)>>,
        fail: bool,
    }

    impl RecordingWrites {
        fn new(vault: Arc<FakeSecretVault>, fail: bool) -> Self {
            Self {
                vault,
                writes: Mutex::new(Vec::new()),
                fail,
            }
        }

        fn writes(&self) -> Vec<(usize, SavedConnection)> {
            self.writes.lock().unwrap().clone()
        }
    }

    impl ConnectionWrites for RecordingWrites {
        fn upsert(&self, connection: SavedConnection) -> BoxFuture<'_, Result<(), StorageError>> {
            let calls_before = self.vault.calls().len();
            self.writes.lock().unwrap().push((calls_before, connection));
            let fail = self.fail;
            Box::pin(async move {
                if fail {
                    Err(StorageError::Schema("the disk is full".to_owned()))
                } else {
                    Ok(())
                }
            })
        }
    }

    fn connection(id: Uuid) -> SavedConnection {
        SavedConnection {
            id,
            name: "Prod".into(),
            driver_id: "postgres".into(),
            host: "db.example.com".into(),
            port: 5432,
            database: "shop".into(),
            username: "app".into(),
            tls: TlsConfig::verify_full(),
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: Some(SavedSshConfig {
                host: "bastion.example.com".into(),
                port: None,
                username: Some("deploy".into()),
                jump_hosts: Vec::new(),
                auth: SavedSshAuth::PrivateKey {
                    path: Some("/home/u/.ssh/id_ed25519".into()),
                    has_passphrase: true,
                },
            }),
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn secret(kind: SecretKind) -> SecretSave {
        SecretSave {
            kind,
            secret: SecretString::from("s3cret"),
            label: format!("{kind:?}"),
        }
    }

    fn save(id: Uuid, is_new: bool) -> PendingSave {
        PendingSave {
            connection: connection(id),
            secrets: vec![secret(SecretKind::DatabasePassword), secret(SecretKind::SshPassphrase)],
            is_new,
        }
    }

    #[tokio::test]
    async fn secrets_written_before_entry() {
        let vault = Arc::new(FakeSecretVault::new());
        let writes = RecordingWrites::new(vault.clone(), false);
        let id = Uuid::new_v4();

        let report = persist_pending_save(&*vault, &writes, save(id, true)).await.unwrap();

        assert_eq!(
            vault.calls(),
            vec![
                Call::Store(id, SecretKind::DatabasePassword),
                Call::Store(id, SecretKind::SshPassphrase)
            ]
        );
        let writes = writes.writes();
        assert_eq!(writes.len(), 1, "the entry was written more than once");
        assert_eq!(writes[0].0, 2, "the entry was written before its secrets");
        assert!(report.secret_failures.is_empty());
        assert!(report.saved.has_stored_passphrase());
    }

    #[tokio::test]
    async fn keyring_failure_still_saves_the_entry_and_reports_it() {
        let vault = Arc::new(FakeSecretVault::new());
        vault.fail_store(SecretKind::SshPassphrase, SecretError::Locked);
        let writes = RecordingWrites::new(vault.clone(), false);
        let id = Uuid::new_v4();

        let report = persist_pending_save(&*vault, &writes, save(id, true)).await.unwrap();

        assert_eq!(
            report.secret_failures,
            vec![(SecretKind::SshPassphrase, SecretError::Locked)]
        );
        let writes = writes.writes();
        assert_eq!(writes.len(), 1, "a refused secret stopped the save");
        assert!(
            !writes[0].1.has_stored_passphrase(),
            "the entry claims a passphrase the keyring refused"
        );
        assert!(!report.saved.has_stored_passphrase());
    }

    #[tokio::test]
    async fn new_connection_write_failure_deletes_its_secrets() {
        let vault = Arc::new(FakeSecretVault::new());
        let writes = RecordingWrites::new(vault.clone(), true);
        let id = Uuid::new_v4();

        let refused = persist_pending_save(&*vault, &writes, save(id, true)).await;

        assert!(refused.is_err());
        assert!(vault.is_empty(), "secrets outlived the connection that never saved");
        assert!(vault.calls().contains(&Call::DeleteConnection(id)));
    }

    #[tokio::test]
    async fn an_existing_connection_keeps_its_secrets_when_the_write_fails() {
        let vault = Arc::new(FakeSecretVault::new());
        let writes = RecordingWrites::new(vault.clone(), true);
        let id = Uuid::new_v4();

        let refused = persist_pending_save(&*vault, &writes, save(id, false)).await;

        assert!(refused.is_err());
        assert!(!vault.is_empty());
        assert!(!vault.calls().contains(&Call::DeleteConnection(id)));
    }

    #[tokio::test]
    async fn the_store_writes_the_entry_off_the_runtime_workers() {
        let root = tempfile::tempdir().unwrap();
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let writes = StoreConnectionWrites::new(store.clone(), paused_tasks());
        let vault = FakeSecretVault::new();
        let id = Uuid::new_v4();

        persist_pending_save(&vault, &writes, save(id, true)).await.unwrap();

        let list = store.load_blocking().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, id);
    }
}
