#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tablepro_ffi::{
    CloudConnectionFields, CloudGroupFields, CloudLibraryPull, CloudLibraryRecords, ConnectionLibrary,
    ConnectionRecord, ConnectionSecrets, Core, HostConfig, HostSecretError, HostSecrets, SafeModeTag, SecretItemTag,
    SecretKindTag, TlsModeTag, TlsSettings,
};
use tempfile::TempDir;

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

fn library(dir: &TempDir) -> Arc<ConnectionLibrary> {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.path().display().to_string()),
        },
        Box::new(MemorySecrets::default()),
    )
    .unwrap();
    core.library().unwrap()
}

async fn saved(library: &ConnectionLibrary, name: &str) -> String {
    let record = ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.internal".to_owned(),
        port: 5432,
        database: "app".to_owned(),
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
    };
    library.save(record, ConnectionSecrets::default()).await.unwrap().id
}

#[tokio::test]
async fn a_library_writes_its_records_and_then_has_nothing_to_send() {
    let dir = TempDir::new().unwrap();
    let library = library(&dir);
    let work = library.create_group("Work".to_owned(), None).await.unwrap();
    let id = saved(&library, "production").await;
    library
        .move_to_group(vec![id.clone()], Some(work.id.clone()), None)
        .await
        .unwrap();
    library.set_favorite(id.clone(), true).await.unwrap();

    let sent = library.cloud_edits(CloudLibraryRecords::default()).await.unwrap();

    assert_eq!(
        sent.groups,
        [CloudGroupFields {
            group_id: work.id.to_uppercase(),
            name: Some("Work".to_owned()),
            color: Some("None".to_owned()),
            icon_name: None,
            parent_id: None,
            sort_order: Some(0),
        }]
    );
    assert_eq!(
        sent.connections,
        [CloudConnectionFields {
            connection_id: id.to_uppercase(),
            name: Some("production".to_owned()),
            group_id: Some(work.id.to_uppercase()),
            sort_order: Some(0),
            is_favorite: Some(1),
        }]
    );
    assert_eq!(library.cloud_edits(sent).await.unwrap(), CloudLibraryRecords::default());
}

#[tokio::test]
async fn a_pull_files_connections_under_the_groups_another_mac_made() {
    let dir = TempDir::new().unwrap();
    let library = library(&dir);
    let id = saved(&library, "production").await;
    let group_id = "6F9619FF-8B86-D011-B42D-00C04FC964FF".to_owned();
    let changed = CloudLibraryRecords {
        groups: vec![CloudGroupFields {
            group_id: group_id.clone(),
            name: Some("Clients\t".to_owned()),
            color: Some("Gray".to_owned()),
            icon_name: Some("person.2".to_owned()),
            parent_id: None,
            sort_order: Some(4),
        }],
        connections: vec![CloudConnectionFields {
            connection_id: id.to_uppercase(),
            name: Some("production".to_owned()),
            group_id: Some(group_id.clone()),
            sort_order: Some(9),
            is_favorite: Some(1),
        }],
    };

    library
        .apply_cloud_pull(CloudLibraryPull {
            changed: changed.clone(),
            ..CloudLibraryPull::default()
        })
        .await
        .unwrap();

    let snapshot = library.snapshot().await.unwrap();
    assert_eq!(snapshot.groups.len(), 1);
    assert_eq!(snapshot.groups[0].name, "Clients");
    assert_eq!(snapshot.groups[0].color.as_deref(), Some("slate"));
    assert_eq!(snapshot.connections[0].group_id, Some(group_id.to_lowercase()));
    assert_eq!(snapshot.favorites, [id]);
    assert_eq!(
        library.cloud_edits(changed).await.unwrap(),
        CloudLibraryRecords::default()
    );
}

#[tokio::test]
async fn cloud_deletions_remove_secrets_only_after_storage_succeeds() {
    let dir = TempDir::new().unwrap();
    let secrets = MemorySecrets::default();
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.path().display().to_string()),
        },
        Box::new(secrets.clone()),
    )
    .unwrap();
    let library = core.library().unwrap();
    let id = saved(&library, "production").await;
    secrets
        .store(
            id.clone(),
            SecretKindTag::DatabasePassword,
            "password".to_owned(),
            "test".to_owned(),
        )
        .unwrap();
    let pull = CloudLibraryPull {
        deleted_connection_ids: vec![id.clone()],
        ..CloudLibraryPull::default()
    };
    let file = dir.path().join("connections.json");
    let contents = std::fs::read(&file).unwrap();
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    assert!(library.apply_cloud_pull(pull.clone()).await.is_err());
    assert_eq!(
        secrets
            .load(id.clone(), SecretKindTag::DatabasePassword)
            .unwrap()
            .as_deref(),
        Some("password")
    );
    std::fs::remove_dir(&file).unwrap();
    std::fs::write(&file, contents).unwrap();
    library.apply_cloud_pull(pull).await.unwrap();
    assert!(library.snapshot().await.unwrap().connections.is_empty());
    assert_eq!(secrets.load(id, SecretKindTag::DatabasePassword).unwrap(), None);
}
