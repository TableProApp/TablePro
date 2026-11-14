#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, HostConfig, HostSecretError, HostSecrets, SafeModeTag, SecretItemTag,
    SecretKindTag, SshAuthTag, SshSettings, TlsModeTag, TlsSettings,
};

type Stored = Arc<Mutex<HashMap<(String, SecretKindTag), SecretString>>>;

// Refuses every store while `locked` is set, as a locked keychain does.
#[derive(Default, Clone)]
struct MemorySecrets {
    held: Stored,
    locked: Arc<AtomicBool>,
}

impl MemorySecrets {
    fn value(&self, id: &str, kind: SecretKindTag) -> Option<String> {
        self.held
            .lock()
            .unwrap()
            .get(&(id.to_owned(), kind))
            .map(|secret| secret.expose_secret().to_owned())
    }

    fn ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.held.lock().unwrap().keys().map(|(id, _)| id.clone()).collect();
        ids.sort();
        ids.dedup();
        ids
    }
}

impl HostSecrets for MemorySecrets {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.held.lock().unwrap().get(&(connection_id, kind)).cloned())
    }

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: SecretString,
        _: String,
    ) -> Result<(), HostSecretError> {
        if self.locked.load(Ordering::SeqCst) {
            return Err(HostSecretError::Locked);
        }
        self.held.lock().unwrap().insert((connection_id, kind), secret);
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
        self.held.lock().unwrap().remove(&(connection_id, kind));
        Ok(())
    }

    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError> {
        self.held.lock().unwrap().retain(|(id, _), _| *id != connection_id);
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

fn record(name: &str) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.example.com".to_owned(),
        port: 5432,
        database: "shop".to_owned(),
        username: "app".to_owned(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Require,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: Some(SshSettings {
            host: "bastion.example.com".to_owned(),
            port: Some(22),
            username: Some("ops".to_owned()),
            jump_hosts: Vec::new(),
            auth: SshAuthTag::Password,
        }),
        safe_mode: SafeModeTag::ConfirmWrites,
        query_timeout_secs: Some(30),
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
    }
}

fn secrets() -> ConnectionSecrets {
    ConnectionSecrets {
        database_password: Some(SecretString::from("hunter2")),
        ssh_password: Some(SecretString::from("tunnel")),
        ..ConnectionSecrets::default()
    }
}

#[tokio::test]
async fn a_copy_lands_after_its_original_with_a_new_id_and_every_secret() {
    let dir = tempfile::tempdir().unwrap();
    let vault = MemorySecrets::default();
    let library = core(dir.path(), vault.clone()).library().unwrap();
    let group = library.create_group("Work".to_owned(), None).await.unwrap();
    let mut shop = record("Shop");
    shop.group_id = Some(group.id.clone());
    let shop = library.save(shop, secrets()).await.unwrap();
    let mut after = record("After");
    after.group_id = Some(group.id.clone());
    let after = library.save(after, ConnectionSecrets::default()).await.unwrap();
    library.set_favorite(shop.id.clone(), true).await.unwrap();

    let copy = library
        .duplicate(shop.id.clone(), " Shop (Copy) ".to_owned())
        .await
        .unwrap();
    let snapshot = library.snapshot().await.unwrap();

    assert_ne!(copy.id, shop.id);
    assert_eq!(copy.name, "Shop (Copy)");
    assert_eq!(copy.group_id.as_deref(), Some(group.id.as_str()));
    assert_eq!((copy.host.as_str(), copy.port), ("db.example.com", 5432));
    assert_eq!(copy.ssh, shop.ssh);
    assert_eq!(copy.safe_mode, SafeModeTag::ConfirmWrites);
    assert_eq!(copy.last_opened_ms, None);
    let order: Vec<&str> = snapshot.connections.iter().map(|saved| saved.id.as_str()).collect();
    assert_eq!(order, [shop.id.as_str(), copy.id.as_str(), after.id.as_str()]);
    assert_eq!(snapshot.favorites, std::slice::from_ref(&shop.id));
    for kind in [SecretKindTag::DatabasePassword, SecretKindTag::SshPassword] {
        assert_eq!(vault.value(&copy.id, kind), vault.value(&shop.id, kind), "{kind:?}");
    }
    assert_eq!(
        vault.value(&copy.id, SecretKindTag::DatabasePassword).as_deref(),
        Some("hunter2")
    );

    library.delete(shop.id.clone()).await.unwrap();
    assert_eq!(
        vault.value(&copy.id, SecretKindTag::SshPassword).as_deref(),
        Some("tunnel")
    );
}

#[tokio::test]
async fn a_copy_whose_secrets_are_refused_is_not_saved_and_leaves_none_behind() {
    let dir = tempfile::tempdir().unwrap();
    let vault = MemorySecrets::default();
    let library = core(dir.path(), vault.clone()).library().unwrap();
    let shop = library.save(record("Shop"), secrets()).await.unwrap();
    vault.locked.store(true, Ordering::SeqCst);

    let refused = library
        .duplicate(shop.id.clone(), "Shop (Copy)".to_owned())
        .await
        .unwrap_err();
    let unnamed = library.duplicate(shop.id.clone(), "  ".to_owned()).await.unwrap_err();
    let unknown = library
        .duplicate("6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11".to_owned(), "Gone".to_owned())
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "secret.locked");
    assert_eq!(unnamed.code(), "library.name_required");
    assert_eq!(unknown.code(), "storage.connection_not_found");
    assert_eq!(library.snapshot().await.unwrap().connections.len(), 1);
    assert_eq!(vault.ids(), [shop.id]);
}

#[tokio::test]
async fn an_exported_file_holds_every_connection_and_no_secret_and_imports_back() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(&dir.path().join("one"), MemorySecrets::default())
        .library()
        .unwrap();
    library.save(record("Shop"), secrets()).await.unwrap();
    library
        .save(record("Warehouse"), ConnectionSecrets::default())
        .await
        .unwrap();
    let file = dir.path().join("connections.json");

    let count = library.export_file(file.display().to_string()).await.unwrap();
    let text = std::fs::read_to_string(&file).unwrap();
    let elsewhere = core(&dir.path().join("two"), MemorySecrets::default())
        .library()
        .unwrap();
    let imported = elsewhere.import_file(file.display().to_string()).await.unwrap();
    let relative = library.export_file("connections.json".to_owned()).await.unwrap_err();

    assert_eq!(count, 2);
    assert!(text.contains("db.example.com") && text.contains("Warehouse"), "{text}");
    assert!(!text.contains("hunter2") && !text.contains("tunnel"), "{text}");
    assert_eq!((imported.added, imported.updated), (2, 0));
    assert_eq!(relative.code(), "ffi.export_bad_path");
    let leftovers: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".part"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}
