//! The saved-connection library and connecting through it, with the API the bindings see.

#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, FileOpenRequest, HostConfig, HostSecretError, HostSecrets,
    ObjectScopeArg, RunOutcome, RunSettings, SafeModeTag, SecretItemTag, SecretKindTag, TableName, TlsModeTag,
    TlsSettings,
};

type Stored = Arc<Mutex<HashMap<(String, SecretKindTag), String>>>;

#[derive(Default, Clone)]
struct MemorySecrets(Stored);

impl HostSecrets for MemorySecrets {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<String>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&(connection_id, kind)).cloned())
    }

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: String,
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

    fn load_item(&self, _: SecretItemTag) -> Result<Option<String>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

fn core(dir: &Path, secrets: MemorySecrets) -> Arc<Core> {
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
                database_password: Some("hunter2".to_owned()),
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

    assert_eq!(kept.as_deref(), Some("hunter2"));
    assert!(secrets.0.lock().unwrap().is_empty());
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
        .connect_saved(saved.id.clone(), ConnectionSecrets::default(), None)
        .await
        .unwrap();
    let objects = session.objects(ObjectScopeArg::DefaultSchema, None).await.unwrap();
    let browse = session
        .browse_sql(
            TableName {
                schema: None,
                name: "people".to_owned(),
            },
            100,
        )
        .unwrap();
    session.close().await.unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert!(objects.iter().any(|object| object.name == "people"));
    assert!(browse.starts_with("SELECT * FROM \"people\""), "{browse}");
    assert!(browse.contains("100"), "{browse}");
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
    )
    .await
    .unwrap();
    let missing = core
        .test_connection(
            record("gone", "sqlite", &dir.path().join("gone.sqlite").display().to_string()),
            ConnectionSecrets::default(),
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
        .connect_saved(saved.id, ConnectionSecrets::default(), None)
        .await
        .unwrap_err();

    assert_eq!(error.code(), "keyring.secret_not_stored");
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
