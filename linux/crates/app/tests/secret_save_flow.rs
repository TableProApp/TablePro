//! How a connection's secrets reach the keyring and come back, proved
//! against a fake vault and the real connection list on disk.
//!
//! Saving writes secrets first, then the entry once. A secret the
//! keyring refuses does not stop the save: the entry is kept without it
//! and the user is asked for it at the next connect, which is also what
//! happens to a connection whose password was never stored.

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{
    CredentialInteraction, PromptReply, SecretError, SecretKind, SecretSave, SecretVault,
};
use tablepro_core::{AuthMode, Credentials, DriverRegistry, TlsConfig};
use tablepro_session::connect::StoreConnectionWrites;
use tablepro_session::runtime::Tasks;
use tablepro_session::{ConnectError, PendingSave, RequestTarget, persist_pending_save, resolve_saved};
use tablepro_storage::{
    ConnectionStore, CredentialDemand, KeyringCredentials, KeyringError, SavedConnection, SavedSshAuth, SavedSshConfig,
    StorageError, StoragePaths,
};
use tablepro_test_support::{Call, ConnectionScript, FakeDriver, FakePrompter, FakeSecretVault};
use uuid::Uuid;

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel")
}

#[expect(
    clippy::disallowed_methods,
    reason = "a test is already inside its own runtime; the app takes the handle from AppRuntime"
)]
fn tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}

fn connection(id: Uuid, ssh: Option<SavedSshConfig>) -> SavedConnection {
    SavedConnection {
        id,
        name: "Prod".into(),
        driver_id: "fake".into(),
        host: "db.example.com".into(),
        port: 5432,
        database: "shop".into(),
        username: "app".into(),
        tls: TlsConfig::verify_full(),
        read_only: false,
        auth_mode: AuthMode::Password,
        ssh,
        last_opened_at: None,
        color: None,
        group: None,
    }
}

fn keyed_ssh() -> SavedSshConfig {
    SavedSshConfig {
        host: "bastion.example.com".into(),
        port: None,
        username: Some("deploy".into()),
        jump_hosts: Vec::new(),
        auth: SavedSshAuth::PrivateKey {
            path: Some("/home/u/.ssh/id_ed25519".into()),
            // The save records whether the passphrase actually landed.
            has_passphrase: true,
        },
    }
}

fn passphrase() -> SecretSave {
    SecretSave {
        kind: SecretKind::SshPassphrase,
        secret: SecretString::from("pass"),
        label: "TablePro SSH key passphrase".into(),
    }
}

async fn save(
    vault: &FakeSecretVault,
    store: &ConnectionStore,
    saved: SavedConnection,
    is_new: bool,
) -> Result<tablepro_session::PersistReport, StorageError> {
    let writes = StoreConnectionWrites::new(store.clone(), tasks());
    let pending = PendingSave {
        connection: saved,
        secrets: vec![passphrase()],
        is_new,
    };
    persist_pending_save(vault, &writes, pending).await
}

fn has_passphrase(saved: &SavedConnection) -> bool {
    saved.has_stored_passphrase()
}

#[tokio::test]
async fn secrets_stored_before_single_upsert() {
    let root = tempfile::tempdir().expect("tempdir");
    let vault = FakeSecretVault::new();
    let store = ConnectionStore::new(&paths(&root));
    let id = Uuid::new_v4();

    save(&vault, &store, connection(id, Some(keyed_ssh())), true)
        .await
        .expect("save");

    assert_eq!(vault.calls(), vec![Call::Store(id, SecretKind::SshPassphrase)]);
    let listed = store.load_blocking().expect("load");
    assert_eq!(listed.len(), 1);
    assert!(has_passphrase(&listed[0]));
}

#[tokio::test]
async fn passphrase_store_failure_saves_has_passphrase_false_in_one_write() {
    let root = tempfile::tempdir().expect("tempdir");
    let vault = FakeSecretVault::new();
    vault.fail_store(SecretKind::SshPassphrase, SecretError::Locked);
    let store = ConnectionStore::new(&paths(&root));
    let id = Uuid::new_v4();
    let revision_before = store.snapshot().revision;

    let report = save(&vault, &store, connection(id, Some(keyed_ssh())), true)
        .await
        .expect("the entry is saved without the secret");

    assert!(
        !has_passphrase(&report.saved),
        "the record claims a passphrase the keyring refused"
    );
    assert_eq!(
        report.secret_failures,
        [(SecretKind::SshPassphrase, SecretError::Locked)]
    );
    // One load plus one write, not a write followed by a correction.
    assert_eq!(store.snapshot().revision, revision_before + 2);
}

#[tokio::test]
async fn new_connection_upsert_failure_deletes_stored_secrets() {
    let root = tempfile::tempdir().expect("tempdir");
    let vault = FakeSecretVault::new();
    // A corrupt list makes every write fail, which is what the rollback
    // has to cope with.
    let paths = paths(&root);
    std::fs::create_dir_all(paths.connections_file().parent().expect("parent")).expect("create");
    std::fs::write(paths.connections_file(), "not json").expect("seed");
    let store = ConnectionStore::new(&paths);
    let id = Uuid::new_v4();

    let refused = save(&vault, &store, connection(id, Some(keyed_ssh())), true).await;

    assert!(refused.is_err());
    assert!(vault.is_empty(), "secrets outlived the connection that never saved");
    assert!(vault.calls().contains(&Call::DeleteConnection(id)));
}

#[tokio::test]
async fn an_existing_connection_keeps_its_secrets_when_the_write_fails() {
    let root = tempfile::tempdir().expect("tempdir");
    let vault = FakeSecretVault::new();
    let paths = paths(&root);
    std::fs::create_dir_all(paths.connections_file().parent().expect("parent")).expect("create");
    std::fs::write(paths.connections_file(), "not json").expect("seed");
    let store = ConnectionStore::new(&paths);
    let id = Uuid::new_v4();

    let refused = save(&vault, &store, connection(id, Some(keyed_ssh())), false).await;

    assert!(refused.is_err());
    // The entry already existed, so its secrets still belong to it.
    assert!(!vault.is_empty());
    assert!(!vault.calls().contains(&Call::DeleteConnection(id)));
}

fn drivers() -> DriverRegistry {
    let mut drivers = DriverRegistry::new();
    drivers.register(Arc::new(FakeDriver::connecting(
        &FakeDriver::NETWORK_CAPABILITIES,
        ConnectionScript::default(),
    )));
    drivers
}

fn database_password(target: &RequestTarget) -> Option<String> {
    match target {
        RequestTarget::Network {
            credentials: Credentials::Password { password, .. },
            ..
        } => Some(password.expose_secret().to_owned()),
        _ => None,
    }
}

#[tokio::test]
async fn keyring_credentials_not_stored_is_error_not_empty_password() {
    let vault: Arc<dyn SecretVault> = Arc::new(FakeSecretVault::new());
    let saved = connection(Uuid::new_v4(), None);
    let credentials = KeyringCredentials::for_saved(vault, &saved);

    let resolved = resolve_saved(
        &saved,
        &drivers(),
        &credentials,
        CredentialInteraction::Unattended,
        CredentialDemand::default(),
    )
    .await;

    // The old code turned this into an empty password, which reached the
    // driver and came back as a confusing authentication failure.
    assert_eq!(
        resolved.err(),
        Some(ConnectError::Keyring(KeyringError::SecretNotStored {
            kind: SecretKind::DatabasePassword
        }))
    );
}

#[tokio::test]
async fn a_saved_connection_without_a_password_asks_for_one() {
    let vault: Arc<dyn SecretVault> = Arc::new(FakeSecretVault::new());
    let saved = connection(Uuid::new_v4(), None);
    let credentials = KeyringCredentials::for_saved(vault, &saved);
    let prompter = Arc::new(FakePrompter::new([PromptReply::Submitted {
        values: vec![SecretString::from("typed")],
        remember: true,
    }]));

    let refreshed = resolve_saved(
        &saved,
        &drivers(),
        &credentials,
        CredentialInteraction::Attended(prompter),
        CredentialDemand::default(),
    )
    .await
    .expect("the prompt supplies the password");

    assert_eq!(database_password(&refreshed.request.target).as_deref(), Some("typed"));
    assert_eq!(refreshed.remember.len(), 1, "remember was asked for and dropped");
    assert_eq!(refreshed.remember[0].kind, SecretKind::DatabasePassword);
}

#[tokio::test]
async fn keyring_credentials_found_injects_secret() {
    let fake = Arc::new(FakeSecretVault::new());
    let saved = connection(Uuid::new_v4(), None);
    fake.store(
        saved.id,
        SecretKind::DatabasePassword,
        &SecretString::from("stored"),
        "label",
    )
    .await
    .expect("seed the keyring");
    let vault: Arc<dyn SecretVault> = fake;
    let credentials = KeyringCredentials::for_saved(vault, &saved);

    let refreshed = resolve_saved(
        &saved,
        &drivers(),
        &credentials,
        CredentialInteraction::Unattended,
        CredentialDemand::default(),
    )
    .await
    .expect("the stored password is used");

    assert_eq!(database_password(&refreshed.request.target).as_deref(), Some("stored"));
    assert!(refreshed.remember.is_empty());
}
