#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use russh::keys::HashAlg;
use russh::keys::ssh_key::PrivateKey;
use russh::keys::ssh_key::private::Ed25519Keypair;
use secrecy::{ExposeSecret, SecretString};
use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, CoreError, FileOpenRequest, HostConfig, HostPrompter, HostSecretError,
    HostSecrets, ObjectScopeArg, PromptAnswer, PromptPurposeTag, PromptRequest, RunOutcome, RunSettings, SafeModeTag,
    SecretItemTag, SecretKindTag, SshAuthTag, SshSettings, TableName, TlsModeTag, TlsSettings,
};
use tokio::net::TcpListener;

type Stored = Arc<Mutex<HashMap<(String, SecretKindTag), SecretString>>>;

#[derive(Default, Clone)]
struct MemorySecrets(Stored);

impl HostSecrets for MemorySecrets {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&(connection_id, kind)).cloned())
    }

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: SecretString,
        _: String,
    ) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().insert((connection_id, kind), secret);
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().remove(&(connection_id, kind));
        Ok(())
    }

    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().retain(|(id, _), _| *id != connection_id);
        Ok(())
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

// Refuses a store of the kinds listed, and every delete while deletes are refused, as a locked keychain does.
#[derive(Default, Clone)]
struct RefusingSecrets {
    memory: MemorySecrets,
    refused_kinds: Arc<Mutex<Vec<SecretKindTag>>>,
    refuse_deletes: Arc<AtomicBool>,
    // A refused store that wrote before it failed, as a call that times out can.
    write_refused: Arc<AtomicBool>,
}

impl RefusingSecrets {
    fn refuse(&self, kinds: &[SecretKindTag], deletes: bool) {
        *self.refused_kinds.lock().unwrap() = kinds.to_vec();
        self.refuse_deletes.store(deletes, Ordering::SeqCst);
    }

    fn held(&self) -> Vec<(String, SecretKindTag)> {
        self.memory.0.lock().unwrap().keys().cloned().collect()
    }

    fn value(&self, id: &str, kind: SecretKindTag) -> Option<String> {
        self.memory
            .0
            .lock()
            .unwrap()
            .get(&(id.to_owned(), kind))
            .map(|secret| secret.expose_secret().to_owned())
    }

    fn deleting(&self) -> Result<(), HostSecretError> {
        match self.refuse_deletes.load(Ordering::SeqCst) {
            true => Err(HostSecretError::Locked),
            false => Ok(()),
        }
    }
}

impl HostSecrets for RefusingSecrets {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        self.memory.load(connection_id, kind)
    }

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: SecretString,
        label: String,
    ) -> Result<(), HostSecretError> {
        if self.refused_kinds.lock().unwrap().contains(&kind) {
            if self.write_refused.load(Ordering::SeqCst) {
                self.memory.store(connection_id, kind, secret, label)?;
            }
            return Err(HostSecretError::Locked);
        }
        self.memory.store(connection_id, kind, secret, label)
    }

    fn relabel(&self, connection_id: String, kind: SecretKindTag, label: String) -> Result<(), HostSecretError> {
        self.memory.relabel(connection_id, kind, label)
    }

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
        self.deleting()?;
        self.memory.delete(connection_id, kind)
    }

    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError> {
        self.deleting()?;
        self.memory.delete_connection(connection_id)
    }

    fn load_item(&self, item: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        self.memory.load_item(item)
    }

    fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError> {
        self.memory.store_item(item, secret)
    }

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError> {
        self.memory.delete_item(item)
    }
}

fn core(dir: &Path, secrets: impl HostSecrets + 'static) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.display().to_string()),
        },
        Box::new(secrets),
    )
    .unwrap()
}

fn record(name: &str, driver_id: &str, database: &str) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: driver_id.to_owned(),
        host: String::new(),
        port: 0,
        database: database.to_owned(),
        username: String::new(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Disable,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode: SafeModeTag::Off,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
    }
}

async fn sqlite_file(core: &Core, path: &Path) {
    let session = core
        .open_file(
            FileOpenRequest {
                path: path.display().to_string(),
                driver_id: None,
                read_only: false,
                create: true,
            },
            None,
        )
        .await
        .unwrap();
    let editor = session.open_editor(None).await.unwrap();
    struct Quiet;
    impl tablepro_ffi::RunListener for Quiet {
        fn events_pending(&self) {}
    }
    let run = editor.run(
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)".to_owned(),
        RunSettings::default(),
        Box::new(Quiet),
    );
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    editor.close().await.unwrap();
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_saved_connection_comes_back_in_its_group_and_among_the_favourites() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();

    let group = library.create_group("Work".to_owned(), None).await.unwrap();
    let nested = library
        .create_group("Staging".to_owned(), Some(group.id.clone()))
        .await
        .unwrap();
    let mut shop = record("shop", "postgres", "shop");
    shop.host = "db.example.com".to_owned();
    shop.port = 5432;
    shop.group_id = Some(nested.id.clone());
    let saved = library.save(shop, ConnectionSecrets::default()).await.unwrap();
    library.set_favorite(saved.id.clone(), true).await.unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(snapshot.groups.len(), 2);
    assert_eq!(snapshot.groups[1].parent_id.as_deref(), Some(group.id.as_str()));
    assert_eq!(snapshot.connections.len(), 1);
    assert_eq!(snapshot.connections[0].group_id.as_deref(), Some(nested.id.as_str()));
    assert_eq!(snapshot.favorites, [saved.id]);
}

#[tokio::test]
async fn saving_again_keeps_the_id_and_takes_the_new_fields() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();

    let first = library
        .save(record("one", "sqlite", "C:/data/one.db"), ConnectionSecrets::default())
        .await
        .unwrap();
    let mut changed = first.clone();
    changed.name = "renamed".to_owned();
    changed.safe_mode = SafeModeTag::ReadOnly;
    let second = library.save(changed, ConnectionSecrets::default()).await.unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(second.id, first.id);
    assert_eq!(snapshot.connections.len(), 1);
    assert_eq!(snapshot.connections[0].name, "renamed");
    assert_eq!(snapshot.connections[0].safe_mode, SafeModeTag::ReadOnly);
}

#[tokio::test]
async fn a_saved_password_goes_to_the_secret_store_and_leaves_with_the_connection() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = MemorySecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();

    let saved = library
        .save(
            record("shop", "mysql", "shop"),
            ConnectionSecrets {
                database_password: Some(SecretString::from("hunter2")),
                ..ConnectionSecrets::default()
            },
        )
        .await
        .unwrap();
    let kept = secrets
        .0
        .lock()
        .unwrap()
        .get(&(saved.id.clone(), SecretKindTag::DatabasePassword))
        .cloned();
    library.delete(saved.id.clone()).await.unwrap();

    assert_eq!(kept.as_ref().map(ExposeSecret::expose_secret), Some("hunter2"));
    assert!(secrets.0.lock().unwrap().is_empty());
    assert!(library.snapshot().await.unwrap().connections.is_empty());
}

fn with_password(password: &str) -> ConnectionSecrets {
    ConnectionSecrets {
        database_password: Some(SecretString::from(password)),
        ..ConnectionSecrets::default()
    }
}

#[tokio::test]
async fn a_save_refused_before_any_write_stores_none_of_its_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = MemorySecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();
    let mut bad_id = record("shop", "mysql", "shop");
    bad_id.id = "not-an-id".to_owned();

    let unnamed = library
        .save(record("  ", "mysql", "shop"), with_password("hunter2"))
        .await
        .unwrap_err();
    let invalid = library.save(bad_id, with_password("hunter2")).await.unwrap_err();

    assert_eq!(unnamed.code(), "library.name_required");
    assert_eq!(invalid.code(), "library.invalid_id");
    assert!(secrets.0.lock().unwrap().is_empty());
    assert!(library.snapshot().await.unwrap().connections.is_empty());
}

#[tokio::test]
async fn a_delete_the_secret_store_refuses_keeps_the_connection_and_its_password() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();
    let saved = library
        .save(record("shop", "mysql", "shop"), with_password("hunter2"))
        .await
        .unwrap();

    secrets.refuse(&[], true);
    let refused = library.delete(saved.id.clone()).await.unwrap_err();

    assert_eq!(refused.code(), "secret.locked");
    assert_eq!(library.snapshot().await.unwrap().connections.len(), 1);
    assert_eq!(secrets.held(), [(saved.id.clone(), SecretKindTag::DatabasePassword)]);

    secrets.refuse(&[], false);
    library.delete(saved.id).await.unwrap();

    assert!(library.snapshot().await.unwrap().connections.is_empty());
    assert!(secrets.held().is_empty());
}

#[tokio::test]
async fn a_new_connection_whose_password_is_refused_is_not_saved_so_a_retry_adds_it_once() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();

    secrets.refuse(&[SecretKindTag::DatabasePassword], true);
    let refused = library
        .save(record("shop", "mysql", "shop"), with_password("hunter2"))
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "secret.locked");
    assert!(library.snapshot().await.unwrap().connections.is_empty());

    secrets.refuse(&[], false);
    let saved = library
        .save(record("shop", "mysql", "shop"), with_password("hunter2"))
        .await
        .unwrap();

    assert_eq!(library.snapshot().await.unwrap().connections.len(), 1);
    assert_eq!(secrets.held(), [(saved.id, SecretKindTag::DatabasePassword)]);
}

#[tokio::test]
async fn a_refused_ssh_password_takes_back_the_new_connection_and_its_database_password() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();
    let both = ConnectionSecrets {
        ssh_password: Some(SecretString::from("tunnel")),
        ..with_password("hunter2")
    };

    secrets.refuse(&[SecretKindTag::SshPassword], false);
    let refused = library.save(through_ssh(22), both.clone()).await.unwrap_err();

    assert_eq!(refused.code(), "secret.locked");
    assert!(library.snapshot().await.unwrap().connections.is_empty());
    assert!(secrets.held().is_empty());

    // With the database password in and no way to take it out, the entry stays to name it.
    secrets.refuse(&[SecretKindTag::SshPassword], true);
    let kept = library.save(through_ssh(22), both).await.unwrap_err();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(kept.code(), "secret.locked");
    assert_eq!(snapshot.connections.len(), 1);
    assert_eq!(
        secrets.held(),
        [(snapshot.connections[0].id.clone(), SecretKindTag::DatabasePassword)]
    );
}

#[tokio::test]
async fn a_refused_store_that_wrote_anyway_leaves_no_secret_behind_a_new_connection() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();

    secrets.refuse(&[SecretKindTag::DatabasePassword], false);
    secrets.write_refused.store(true, Ordering::SeqCst);
    let refused = library
        .save(record("shop", "mysql", "shop"), with_password("hunter2"))
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "secret.locked");
    assert!(library.snapshot().await.unwrap().connections.is_empty());
    assert!(secrets.held().is_empty());
}

#[tokio::test]
async fn an_edit_whose_password_is_refused_keeps_the_old_host_and_the_old_password() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();
    let mut prod = record("shop", "mysql", "shop");
    prod.host = "prod-db.internal".to_owned();
    prod.port = 3306;
    let saved = library.save(prod, with_password("prod-secret")).await.unwrap();
    let mut staging = saved.clone();
    staging.host = "staging-db.internal".to_owned();

    secrets.refuse(&[SecretKindTag::DatabasePassword], false);
    secrets.write_refused.store(true, Ordering::SeqCst);
    let refused = library
        .save(staging, with_password("staging-secret"))
        .await
        .unwrap_err();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(refused.code(), "secret.locked");
    assert_eq!(snapshot.connections[0].host, "prod-db.internal");
    assert_eq!(
        secrets.value(&saved.id, SecretKindTag::DatabasePassword).as_deref(),
        Some("prod-secret")
    );
}

#[tokio::test]
async fn an_edit_refused_at_its_second_secret_takes_back_the_first() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = RefusingSecrets::default();
    let core = core(dir.path(), secrets.clone());
    let library = core.library().unwrap();
    let saved = library
        .save(
            through_ssh(22),
            ConnectionSecrets {
                ssh_password: Some(SecretString::from("old-tunnel")),
                ..ConnectionSecrets::default()
            },
        )
        .await
        .unwrap();
    let mut moved = saved.clone();
    moved.host = "10.0.0.9".to_owned();

    secrets.refuse(&[SecretKindTag::SshPassword], false);
    let refused = library
        .save(
            moved,
            ConnectionSecrets {
                ssh_password: Some(SecretString::from("new-tunnel")),
                ..with_password("new-db")
            },
        )
        .await
        .unwrap_err();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(refused.code(), "secret.locked");
    assert_eq!(snapshot.connections[0].host, saved.host);
    // The database password had none before the edit, so the one the edit wrote is gone again.
    assert_eq!(secrets.value(&saved.id, SecretKindTag::DatabasePassword), None);
    assert_eq!(
        secrets.value(&saved.id, SecretKindTag::SshPassword).as_deref(),
        Some("old-tunnel")
    );
}

#[tokio::test]
async fn half_a_client_certificate_is_refused_by_save_and_by_test() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let mut certificate_only = record("shop", "postgres", "shop");
    certificate_only.host = "127.0.0.1".to_owned();
    certificate_only.port = 1;
    certificate_only.tls.mode = TlsModeTag::Require;
    certificate_only.tls.client_certificate = Some("/certs/client.pem".to_owned());
    let mut key_only = certificate_only.clone();
    key_only.tls.client_certificate = None;
    key_only.tls.client_key = Some("/certs/client.key".to_owned());

    for half in [certificate_only, key_only] {
        let saved = library
            .save(half.clone(), ConnectionSecrets::default())
            .await
            .unwrap_err();
        let tested = core
            .test_connection(half, with_password("typed"), None, None)
            .await
            .unwrap_err();

        assert_eq!(saved.code(), "config.client_identity_incomplete");
        assert_eq!(tested.code(), "config.client_identity_incomplete");
    }
    assert!(library.snapshot().await.unwrap().connections.is_empty());
}

#[tokio::test]
async fn a_saved_sqlite_file_connects_lists_its_tables_and_becomes_recent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    sqlite_file(&core, &path).await;
    let library = core.library().unwrap();
    let saved = library
        .save(
            record("people", "sqlite", &path.display().to_string()),
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();

    let session = core
        .connect_saved(saved.id.clone(), ConnectionSecrets::default(), None, None)
        .await
        .unwrap();
    struct Quiet;
    impl tablepro_ffi::RunListener for Quiet {
        fn events_pending(&self) {}
    }
    let objects = session.objects(ObjectScopeArg::DefaultSchema, None).await.unwrap();
    let browse = session
        .read_table_page(
            TableName {
                schema: None,
                name: "people".to_owned(),
            },
            None,
            None,
            100,
            0,
            Box::new(Quiet),
            None,
        )
        .await
        .unwrap();
    let outcome = browse.run().outcome().await.unwrap();
    let rows = browse.run().result_set(0).map(|set| set.row_count());
    session.close().await.unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert!(objects.iter().any(|object| object.name == "people"));
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    assert_eq!(rows, Some(0));
    assert_eq!(browse.visible_columns(), 2);
    assert_eq!(snapshot.recent, [saved.id]);
    assert!(snapshot.connections[0].last_opened_ms.is_some());
}

#[tokio::test]
async fn a_test_logs_in_and_a_missing_file_fails_by_code() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("test.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    sqlite_file(&core, &path).await;

    core.test_connection(
        record("test", "sqlite", &path.display().to_string()),
        ConnectionSecrets::default(),
        None,
        None,
    )
    .await
    .unwrap();
    let missing = core
        .test_connection(
            record("gone", "sqlite", &dir.path().join("gone.sqlite").display().to_string()),
            ConnectionSecrets::default(),
            None,
            None,
        )
        .await
        .unwrap_err();

    assert_eq!(missing.code(), "driver.file_not_found");
}

#[tokio::test]
async fn a_network_login_with_no_saved_password_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let mut shop = record("shop", "postgres", "shop");
    shop.host = "127.0.0.1".to_owned();
    shop.port = 1;
    let saved = library.save(shop, ConnectionSecrets::default()).await.unwrap();

    let error = core
        .connect_saved(saved.id, ConnectionSecrets::default(), None, None)
        .await
        .unwrap_err();

    assert_eq!(error.code(), "keyring.secret_not_stored");
    let CoreError::Failed { info } = error else {
        panic!("cancelled")
    };
    assert_eq!(info.secret, Some(SecretKindTag::DatabasePassword));
}

#[tokio::test]
async fn a_password_typed_at_connect_is_used_when_none_is_saved() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let mut shop = record("shop", "postgres", "shop");
    shop.host = "127.0.0.1".to_owned();
    shop.port = 1;
    let saved = library.save(shop, ConnectionSecrets::default()).await.unwrap();

    let error = core
        .connect_saved(
            saved.id,
            ConnectionSecrets {
                database_password: Some(SecretString::from("typed")),
                ..ConnectionSecrets::default()
            },
            None,
            None,
        )
        .await
        .unwrap_err();

    // Past the keyring, the connect reaches the closed port.
    assert_ne!(error.code(), "keyring.secret_not_stored");
}

struct Refusing;

impl russh::server::Handler for Refusing {
    type Error = russh::Error;
}

#[derive(Clone, Default)]
struct Declining(Arc<Mutex<Vec<PromptRequest>>>);

impl HostPrompter for Declining {
    fn prompt(&self, prompt: PromptRequest) -> PromptAnswer {
        self.0.lock().unwrap().push(prompt);
        PromptAnswer::Cancelled
    }
}

// None when the server stops before the connects are done.
async fn against_ssh_server<F: Future>(key: PrivateKey, connect: impl FnOnce(u16) -> F) -> Option<F::Output> {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let config = Arc::new(russh::server::Config {
        keys: vec![key],
        ..russh::server::Config::default()
    });
    let serving = async move {
        while let Ok((stream, _)) = listener.accept().await {
            if let Ok(session) = russh::server::run_stream(config.clone(), stream, Refusing).await {
                session.await.ok();
            }
        }
    };
    tokio::select! {
        done = connect(port) => Some(done),
        () = serving => None,
    }
}

fn through_ssh(port: u16) -> ConnectionRecord {
    let mut shop = record("shop", "postgres", "shop");
    shop.host = "127.0.0.1".to_owned();
    shop.port = 5432;
    shop.ssh = Some(SshSettings {
        host: "127.0.0.1".to_owned(),
        port: Some(port),
        username: Some("tester".to_owned()),
        jump_hosts: Vec::new(),
        auth: SshAuthTag::Password,
    });
    shop
}

#[tokio::test]
async fn an_ssh_login_asks_the_app_about_a_host_key_it_does_not_know() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let key = PrivateKey::from(Ed25519Keypair::from_seed(&[7; 32]));
    let fingerprint = key.public_key().fingerprint(HashAlg::Sha256).to_string();
    let prompter = Declining::default();
    let secrets = ConnectionSecrets {
        database_password: Some(SecretString::from("")),
        ssh_password: Some(SecretString::from("typed")),
        ssh_passphrase: None,
    };

    let prompts = &prompter;
    let (port, unattended, declined) = against_ssh_server(key, |port| async move {
        let unattended = core
            .test_connection(through_ssh(port), secrets.clone(), None, None)
            .await;
        let declined = core
            .test_connection(
                through_ssh(port),
                secrets.clone(),
                Some(Box::new(prompts.clone())),
                None,
            )
            .await;
        (port, unattended, declined)
    })
    .await
    .unwrap();

    assert_eq!(unattended.unwrap_err().code(), "ssh.host_key_unknown");
    assert_eq!(declined.unwrap_err().code(), "ssh.host_key_unknown");
    let asked = prompter.0.lock().unwrap();
    assert_eq!(asked.len(), 1, "{asked:?}");
    assert_eq!(
        asked[0].purpose,
        PromptPurposeTag::SshHostKey {
            host: format!("[127.0.0.1]:{port}"),
            algorithm: "ED25519".to_owned(),
            fingerprint,
        }
    );
}

#[tokio::test]
async fn an_empty_database_password_survives_a_separately_stored_ssh_password() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let key = PrivateKey::from(Ed25519Keypair::from_seed(&[8; 32]));
    against_ssh_server(key, |port| async move {
        let saved = core
            .library()
            .unwrap()
            .save(
                through_ssh(port),
                ConnectionSecrets {
                    ssh_password: Some(SecretString::from("saved ssh password")),
                    ..ConnectionSecrets::default()
                },
            )
            .await
            .unwrap();
        let error = core
            .connect_saved(
                saved.id,
                ConnectionSecrets {
                    database_password: Some(SecretString::from("")),
                    ..ConnectionSecrets::default()
                },
                None,
                None,
            )
            .await
            .unwrap_err();
        assert_eq!(error.code(), "ssh.host_key_unknown");

        let mut with_key = through_ssh(port);
        with_key.ssh.as_mut().unwrap().auth = SshAuthTag::PrivateKey {
            path: Some(dir.path().join("id_ed25519").display().to_string()),
            has_passphrase: false,
        };
        let error = core
            .test_connection(
                with_key,
                ConnectionSecrets {
                    database_password: Some(SecretString::from("")),
                    ..ConnectionSecrets::default()
                },
                None,
                None,
            )
            .await
            .unwrap_err();
        assert_ne!(error.code(), "keyring.secret_not_stored");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_tag_goes_on_several_connections_and_a_rename_reaches_all_of_them() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let one = library
        .save(record("one", "sqlite", "C:/data/one.db"), ConnectionSecrets::default())
        .await
        .unwrap();
    let two = library
        .save(record("two", "sqlite", "C:/data/two.db"), ConnectionSecrets::default())
        .await
        .unwrap();

    let tag = library.create_tag("prod".to_owned(), "red".to_owned()).await.unwrap();
    library
        .tag_connections(vec![one.id.clone(), two.id.clone()], tag.id.clone(), true)
        .await
        .unwrap();
    library
        .update_tag(tag.id.clone(), "production".to_owned(), "orange".to_owned())
        .await
        .unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(snapshot.tags.len(), 1);
    assert_eq!(snapshot.tags[0].name, "production");
    assert_eq!(snapshot.tags[0].color, "orange");
    assert!(snapshot.connections.iter().all(|saved| saved.tags == [tag.id.clone()]));

    library
        .tag_connections(vec![one.id.clone()], tag.id.clone(), false)
        .await
        .unwrap();
    let untagged = library.snapshot().await.unwrap();
    let tags_of = |id: &str| {
        untagged
            .connections
            .iter()
            .find(|saved| saved.id == id)
            .map(|saved| saved.tags.clone())
    };
    assert_eq!(tags_of(&one.id), Some(Vec::new()));
    assert_eq!(tags_of(&two.id), Some(vec![tag.id.clone()]));
}

#[tokio::test]
async fn a_deleted_tag_leaves_every_connection_and_a_taken_name_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let one = library
        .save(record("one", "sqlite", "C:/data/one.db"), ConnectionSecrets::default())
        .await
        .unwrap();
    let tag = library.create_tag("prod".to_owned(), "red".to_owned()).await.unwrap();
    library
        .tag_connections(vec![one.id.clone()], tag.id.clone(), true)
        .await
        .unwrap();

    let taken = library
        .create_tag("PROD".to_owned(), "blue".to_owned())
        .await
        .unwrap_err();
    let empty = library
        .create_tag("  ".to_owned(), "blue".to_owned())
        .await
        .unwrap_err();
    let colour = library
        .create_tag("eu".to_owned(), "beige".to_owned())
        .await
        .unwrap_err();
    library.delete_tag(tag.id.clone()).await.unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(taken.code(), "storage.tag_name_taken");
    assert_eq!(empty.code(), "tag_name.empty");
    assert_eq!(colour.code(), "library.unknown_color");
    assert!(snapshot.tags.is_empty());
    assert!(snapshot.connections[0].tags.is_empty());
}

#[tokio::test]
async fn saving_from_the_form_keeps_the_tags_it_does_not_show() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let saved = library
        .save(record("one", "sqlite", "C:/data/one.db"), ConnectionSecrets::default())
        .await
        .unwrap();
    let tag = library.create_tag("prod".to_owned(), "red".to_owned()).await.unwrap();
    library
        .tag_connections(vec![saved.id.clone()], tag.id.clone(), true)
        .await
        .unwrap();

    let mut edited = saved.clone();
    edited.name = "renamed".to_owned();
    library.save(edited, ConnectionSecrets::default()).await.unwrap();

    assert_eq!(library.snapshot().await.unwrap().connections[0].tags, [tag.id]);
}

#[tokio::test]
async fn a_rename_changes_only_the_name_and_an_empty_one_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let saved = library
        .save(record("one", "sqlite", "C:/data/one.db"), ConnectionSecrets::default())
        .await
        .unwrap();

    library
        .rename_connection(saved.id.clone(), "  Orders  ".to_owned())
        .await
        .unwrap();
    let empty = library
        .rename_connection(saved.id.clone(), " ".to_owned())
        .await
        .unwrap_err();
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(snapshot.connections[0].name, "Orders");
    assert_eq!(snapshot.connections[0].database, "C:/data/one.db");
    assert_eq!(empty.code(), "library.name_required");
}

#[tokio::test]
async fn a_drop_places_connections_before_another_and_reorders_favourites() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let group = library.create_group("Work".to_owned(), None).await.unwrap();
    let mut ids = Vec::new();
    for name in ["a", "b", "c"] {
        let saved = library
            .save(
                record(name, "sqlite", &format!("C:/data/{name}.db")),
                ConnectionSecrets::default(),
            )
            .await
            .unwrap();
        ids.push(saved.id);
    }

    library
        .move_to_group(vec![ids[0].clone(), ids[2].clone()], Some(group.id.clone()), None)
        .await
        .unwrap();
    library
        .move_to_group(vec![ids[1].clone()], Some(group.id.clone()), Some(ids[2].clone()))
        .await
        .unwrap();
    library
        .add_favorites(vec![ids[0].clone(), ids[1].clone()], None)
        .await
        .unwrap();
    library
        .add_favorites(vec![ids[1].clone()], Some(ids[0].clone()))
        .await
        .unwrap();
    let snapshot = library.snapshot().await.unwrap();

    let names: Vec<&str> = snapshot.connections.iter().map(|saved| saved.name.as_str()).collect();
    assert_eq!(names, ["a", "b", "c"]);
    assert!(
        snapshot
            .connections
            .iter()
            .all(|saved| saved.group_id.as_deref() == Some(group.id.as_str()))
    );
    assert_eq!(snapshot.favorites, [ids[1].clone(), ids[0].clone()]);

    library.remove_favorites(vec![ids[1].clone()]).await.unwrap();
    assert_eq!(library.snapshot().await.unwrap().favorites, [ids[0].clone()]);
}

#[tokio::test]
async fn a_group_dropped_on_another_goes_inside_it_but_not_inside_itself() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();
    let work = library.create_group("Work".to_owned(), None).await.unwrap();
    let staging = library.create_group("Staging".to_owned(), None).await.unwrap();

    library
        .move_groups(vec![staging.id.clone()], Some(work.id.clone()), None)
        .await
        .unwrap();
    let inside_itself = library
        .move_groups(vec![work.id.clone()], Some(staging.id.clone()), None)
        .await;
    let snapshot = library.snapshot().await.unwrap();

    assert_eq!(snapshot.groups[1].parent_id.as_deref(), Some(work.id.as_str()));
    assert!(inside_itself.is_err());
}

#[test]
fn a_core_without_a_storage_folder_has_no_library() {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(MemorySecrets::default()),
    )
    .unwrap();

    assert_eq!(core.library().unwrap_err().code(), "ffi.no_storage");
}
