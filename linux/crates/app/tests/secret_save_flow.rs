//! The order the save flow writes in, proved against a fake vault.
//!
//! The rule is: secrets first, then one list write. Anything else either
//! records a passphrase that is not there, or leaves secrets belonging
//! to a connection that was never saved.

use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::AuthMode;
use tablepro_core::credentials::{SecretError, SecretKind, SecretVault};
use tablepro_storage::{ConnectionStore, SavedConnection, SavedSshAuth, SavedSshConfig, StoragePaths};
use tablepro_test_support::{Call, FakeSecretVault};
use uuid::Uuid;

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel")
}

fn connection(id: Uuid, has_passphrase: bool) -> SavedConnection {
    SavedConnection {
        id,
        name: "Prod".into(),
        driver_id: "postgres".into(),
        host: "db.example.com".into(),
        port: 5432,
        database: "shop".into(),
        username: "app".into(),
        use_tls: true,
        read_only: false,
        auth_mode: AuthMode::Password,
        ssh: Some(SavedSshConfig {
            host: "bastion.example.com".into(),
            port: None,
            username: Some("deploy".into()),
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::PrivateKey {
                path: Some("/home/u/.ssh/id_ed25519".into()),
                has_passphrase,
            },
        }),
        last_opened_at: None,
        color: None,
    }
}

/// The save flow as the dialog runs it, reduced to the ordering rule
/// under test.
async fn save(
    vault: &Arc<dyn SecretVault>,
    store: &ConnectionStore,
    mut saved: SavedConnection,
    passphrase: &str,
    is_new: bool,
) -> Result<SavedConnection, String> {
    let stored = vault
        .store(
            saved.id,
            SecretKind::SshPassphrase,
            &SecretString::from(passphrase.to_owned()),
            "TablePro SSH key passphrase",
        )
        .await
        .is_ok();
    if let Some(config) = saved.ssh.as_mut()
        && let SavedSshAuth::PrivateKey { has_passphrase, .. } = &mut config.auth
    {
        *has_passphrase = stored;
    }
    if let Err(error) = store.upsert_blocking(saved.clone()) {
        if is_new {
            let _ = vault.delete_connection(saved.id).await;
        }
        return Err(error.to_string());
    }
    Ok(saved)
}

#[tokio::test]
async fn secrets_stored_before_single_upsert() {
    let root = tempfile::tempdir().expect("tempdir");
    let fake = Arc::new(FakeSecretVault::new());
    let vault: Arc<dyn SecretVault> = fake.clone();
    let store = ConnectionStore::new(&paths(&root));
    let id = Uuid::new_v4();

    save(&vault, &store, connection(id, true), "pass", true)
        .await
        .expect("save");

    assert_eq!(fake.calls(), vec![Call::Store(id, SecretKind::SshPassphrase)]);
    assert_eq!(store.load_blocking().expect("load").len(), 1);
}

#[tokio::test]
async fn passphrase_store_failure_saves_has_passphrase_false_in_one_write() {
    let root = tempfile::tempdir().expect("tempdir");
    let fake = Arc::new(FakeSecretVault::new());
    fake.fail_store(SecretKind::SshPassphrase, SecretError::Locked);
    let vault: Arc<dyn SecretVault> = fake.clone();
    let store = ConnectionStore::new(&paths(&root));
    let id = Uuid::new_v4();
    let revision_before = store.snapshot().revision;

    let saved = save(&vault, &store, connection(id, true), "pass", true)
        .await
        .expect("save");

    let SavedSshAuth::PrivateKey { has_passphrase, .. } = saved.ssh.expect("ssh").auth else {
        panic!("expected a private key");
    };
    assert!(!has_passphrase, "the record claims a passphrase the keyring refused");
    // One load plus one write, not a write followed by a correction.
    assert_eq!(store.snapshot().revision, revision_before + 2);
}

#[tokio::test]
async fn new_connection_upsert_failure_deletes_stored_secrets() {
    let root = tempfile::tempdir().expect("tempdir");
    let fake = Arc::new(FakeSecretVault::new());
    let vault: Arc<dyn SecretVault> = fake.clone();
    // A corrupt list makes every write fail, which is what the rollback
    // has to cope with.
    let paths = paths(&root);
    std::fs::create_dir_all(paths.connections_file().parent().expect("parent")).expect("create");
    std::fs::write(paths.connections_file(), "not json").expect("seed");
    let store = ConnectionStore::new(&paths);
    let id = Uuid::new_v4();

    let refused = save(&vault, &store, connection(id, true), "pass", true).await;

    assert!(refused.is_err());
    assert!(fake.is_empty(), "secrets outlived the connection that never saved");
    assert!(fake.calls().contains(&Call::DeleteConnection(id)));
}

#[tokio::test]
async fn an_existing_connection_keeps_its_secrets_when_the_write_fails() {
    let root = tempfile::tempdir().expect("tempdir");
    let fake = Arc::new(FakeSecretVault::new());
    let vault: Arc<dyn SecretVault> = fake.clone();
    let paths = paths(&root);
    std::fs::create_dir_all(paths.connections_file().parent().expect("parent")).expect("create");
    std::fs::write(paths.connections_file(), "not json").expect("seed");
    let store = ConnectionStore::new(&paths);
    let id = Uuid::new_v4();

    let refused = save(&vault, &store, connection(id, true), "pass", false).await;

    assert!(refused.is_err());
    // The entry already existed, so its secrets still belong to it.
    assert!(!fake.is_empty());
    assert!(!fake.calls().contains(&Call::DeleteConnection(id)));
}

#[tokio::test]
async fn open_saved_not_stored_is_visible_rather_than_an_empty_password() {
    let fake = FakeSecretVault::new();

    let looked_up = fake
        .load(Uuid::new_v4(), SecretKind::DatabasePassword)
        .await
        .expect("load");

    // The old code turned this into an empty password, which reached the
    // driver and came back as a confusing authentication failure.
    assert!(!looked_up.is_stored());
    assert!(looked_up.found().is_none());
}
