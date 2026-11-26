// The connection library's adapters over the core's own stores on the TablePro Sync path (0054, Adapters, Rules for
// both providers): two devices converge on every kind connections.json and the history database hold, what only one
// device holds stays there, and a Local only connection never reaches the server.

use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::record_id::uuid_id;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionStore, ConnectionTagName, CredentialProfile,
    QueryHistory, SavedConnection, SshProfile, StoragePaths, TableRef, TableScope,
};
use tablepro_sync::adapters::library;
use tablepro_sync::api::RecordAdapter;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync_testing::FakeServer;
use tempfile::TempDir;
use uuid::Uuid;

use super::harness::{Device, DeviceBuilder, personal};

struct Library {
    _dir: TempDir,
    store: ConnectionStore,
    history: QueryHistory,
}

impl Library {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
        let store = ConnectionStore::new(&paths);
        let history = QueryHistory::open(&paths).await.unwrap();
        Self {
            _dir: dir,
            store,
            history,
        }
    }

    fn adapters(&self) -> Vec<Arc<dyn RecordAdapter>> {
        library::adapters(&self.store, Some(&self.history))
    }

    async fn device(&self, server: &Arc<FakeServer>, row: &str) -> Device {
        DeviceBuilder::new(server, row).core_stores(self.adapters()).build().await
    }
}

const CONNECTION: u128 = 0x6F1C_2A9E_0B4D_4C8E_9A51_3D7E_2B1F_0C44;

fn connection(id: u128, name: &str) -> SavedConnection {
    serde_json::from_value(json!({
        "id": Uuid::from_u128(id),
        "name": name,
        "driver_id": "PostgreSQL",
        "host": "db.internal",
        "port": 5432,
        "database": "shop",
        "username": "app",
        "tls": {"mode": "verify_full"},
        "safe_mode": "alert_full",
        "external_access": "read_only",
        "ai_policy": "ask",
        "ssh": {"host": "bastion", "port": 22, "username": "ops", "auth": {"kind": "agent"},
            "jump_hosts": ["jump@edge:2222"]},
        "startup_sql": "SET search_path TO shop",
    }))
    .unwrap()
}

// Pulls on `device` until nothing waits for the person, saying yes to each value.
async fn take_everything(device: &Device) {
    for _ in 0..8 {
        device.sync().await;
        let waiting = device.sync.approvals().await.unwrap();
        if waiting.is_empty() {
            return;
        }
        for approval in waiting {
            device
                .sync
                .decide_approval(approval.key, approval.field, true)
                .await
                .unwrap();
        }
    }
}

// A connection as both devices hold it, without what each device holds for itself.
fn shared(mut saved: SavedConnection) -> SavedConnection {
    saved.device = Default::default();
    saved.last_opened_at = None;
    saved
}

async fn seed(library: &Library) -> (Uuid, Uuid) {
    let store = &library.store;
    let group = store
        .create_group_blocking(ConnectionGroup {
            color: Some(ConnectionColor::Teal),
            ..ConnectionGroup::new(ConnectionGroupName::new("Work").unwrap(), None)
        })
        .unwrap();
    let tag = store
        .create_tag_blocking(ConnectionTagName::new("prod").unwrap(), ConnectionColor::Red)
        .unwrap();
    let mut saved = connection(CONNECTION, "Shop");
    saved.group_id = Some(group.id);
    saved.tags = vec![tag.id];
    store.upsert_blocking(saved).unwrap();
    let profile: SshProfile = serde_json::from_value(json!({
        "id": Uuid::from_u128(7), "name": "edge", "host": "edge.example.com", "auth": {"kind": "agent"},
    }))
    .unwrap();
    store.save_ssh_profile_blocking(profile).unwrap();
    let credentials: CredentialProfile = serde_json::from_value(json!({
        "id": Uuid::from_u128(8), "name": "ops", "username": "ops", "password": {"mode": "prompt"},
    }))
    .unwrap();
    store.save_credential_profile_blocking(credentials).unwrap();
    let folders = library.history.table_folders();
    let folder = folders
        .create(
            TableScope {
                connection_id: Uuid::from_u128(CONNECTION),
                database: "shop".to_owned(),
                schema: "public".to_owned(),
            },
            "Billing",
        )
        .await
        .unwrap();
    folders
        .file(
            &[TableRef {
                connection_id: Uuid::from_u128(CONNECTION),
                database: "shop".to_owned(),
                schema: "public".to_owned(),
                name: "orders".to_owned(),
            }],
            folder.id,
        )
        .await
        .unwrap();
    (group.id, folder.id)
}

#[tokio::test]
async fn two_devices_converge_on_every_kind_of_the_library_and_only_its_own_state_stays_apart() {
    let server = FakeServer::new();
    let (mac_library, mini_library) = (Library::new().await, Library::new().await);
    let mac = mac_library.device(&server, "dev_mac").await;
    let mini = mini_library.device(&server, "dev_mini").await;
    seed(&mac_library).await;

    mac.sync().await;
    take_everything(&mini).await;
    let mac_list = mac_library.store.list_blocking().unwrap();
    let mini_list = mini_library.store.list_blocking().unwrap();
    let folders = |library: &Library| {
        let folders = library.history.table_folders();
        async move { folders.contents().await.unwrap() }
    };
    let (mac_folders, mini_folders) = (folders(&mac_library).await, folders(&mini_library).await);

    assert_eq!(
        mini_list.connections.iter().cloned().map(shared).collect::<Vec<_>>(),
        mac_list.connections.iter().cloned().map(shared).collect::<Vec<_>>()
    );
    assert_eq!(mini_list.groups, mac_list.groups);
    assert_eq!(mini_list.tags, mac_list.tags);
    assert_eq!(mini_list.ssh_profiles, mac_list.ssh_profiles);
    assert_eq!(mini_list.credential_profiles, mac_list.credential_profiles);
    assert_eq!(mini_folders.folders, mac_folders.folders);
    assert_eq!(mini_folders.items, mac_folders.items);
    assert_eq!(
        mini_list.connections[0].device.origin,
        tablepro_storage::ConnectionOrigin::Known(tablepro_storage::KnownOrigin::Synced)
    );
}

#[tokio::test]
async fn an_edit_and_a_deletion_on_one_device_land_on_the_other_and_nothing_else_goes_up() {
    let server = FakeServer::new();
    let (mac_library, mini_library) = (Library::new().await, Library::new().await);
    let mac = mac_library.device(&server, "dev_mac").await;
    let mini = mini_library.device(&server, "dev_mini").await;
    seed(&mac_library).await;
    mac.sync().await;
    take_everything(&mini).await;
    let settled = mini.sync().await;

    mac_library
        .store
        .update_blocking(Uuid::from_u128(CONNECTION), |saved| saved.name = "Shop 2".to_owned())
        .unwrap();
    mac.sync().await;
    take_everything(&mini).await;
    let renamed = mini_library.store.list_blocking().unwrap().connections[0].name.clone();
    mini_library.store.remove_blocking(Uuid::from_u128(CONNECTION)).unwrap();
    mini.sync().await;
    mac.sync().await;

    assert_eq!(settled.pushed, 0);
    assert_eq!(renamed, "Shop 2");
    assert!(mac_library.store.list_blocking().unwrap().connections.is_empty());
}

#[tokio::test]
async fn a_local_only_connection_and_its_folders_never_reach_the_server() {
    let server = FakeServer::new();
    let mac_library = Library::new().await;
    let mac = mac_library.device(&server, "dev_mac").await;
    seed(&mac_library).await;
    mac_library
        .store
        .update_blocking(Uuid::from_u128(CONNECTION), |saved| saved.device.local_only = true)
        .unwrap();

    mac.sync().await;

    let id = uuid_id(Uuid::from_u128(CONNECTION));
    assert!(server.stored(personal(), "connection", &id).is_none());
    assert!(server.stored(personal(), "group", &uuid_id(mac_library.store.list_blocking().unwrap().groups[0].id)).is_some());
    let folders = mac_library.history.table_folders().contents().await.unwrap();
    assert!(
        server
            .stored(personal(), Kind::TableFolder.as_str(), &uuid_id(folders.folders[0].id))
            .is_none()
    );
}

#[tokio::test]
async fn a_required_an_earlier_ios_build_wrote_sends_nothing_over_the_preferred_the_server_holds() {
    let server = FakeServer::new();
    let (mac_library, ios_library) = (Library::new().await, Library::new().await);
    let mac = mac_library.device(&server, "dev_mac").await;
    let ios = ios_library.device(&server, "dev_ios").await;
    let mut saved = connection(CONNECTION, "Shop");
    saved.tls.mode = tablepro_core::TlsMode::Prefer;
    mac_library.store.upsert_blocking(saved).unwrap();
    mac.sync().await;
    take_everything(&ios).await;

    ios_library
        .store
        .update_blocking(Uuid::from_u128(CONNECTION), |saved| {
            saved.tls.mode = tablepro_core::TlsMode::Require;
            saved.device.tls_mode_unsettled = true;
        })
        .unwrap();
    let pushed = ios.sync().await.pushed;

    let stored: Value = server
        .stored(personal(), "connection", &uuid_id(Uuid::from_u128(CONNECTION)))
        .unwrap()
        .fields
        .unwrap();
    assert_eq!(pushed, 0);
    assert_eq!(stored["ssl_config"]["mode"], json!("Preferred"));
}

#[tokio::test]
async fn a_copy_kept_local_only_takes_neither_a_pulled_edit_nor_a_pulled_deletion() {
    let server = FakeServer::new();
    let (mac_library, mini_library) = (Library::new().await, Library::new().await);
    let mac = mac_library.device(&server, "dev_mac").await;
    let mini = mini_library.device(&server, "dev_mini").await;
    mac_library.store.upsert_blocking(connection(CONNECTION, "Shop")).unwrap();
    mac.sync().await;
    take_everything(&mini).await;
    let id = Uuid::from_u128(CONNECTION);
    mini_library
        .store
        .update_blocking(id, |saved| saved.device.local_only = true)
        .unwrap();

    mac_library
        .store
        .update_blocking(id, |saved| saved.name = "Shop 2".to_owned())
        .unwrap();
    mac.sync().await;
    take_everything(&mini).await;
    let after_edit = mini_library.store.list_blocking().unwrap().connections[0].name.clone();
    mac_library.store.remove_blocking(id).unwrap();
    mac.sync().await;
    take_everything(&mini).await;

    assert_eq!(after_edit, "Shop");
    assert_eq!(mini_library.store.list_blocking().unwrap().connections.len(), 1);
}
