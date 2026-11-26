// The connection library's adapters over the core's own stores on the CloudKit path (0054, Adapters): what a Mac and
// an iOS build write reads into the stores and sends nothing back, and an edit goes up as the one member it changed.

use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::record_id::table_folder_item;
use tablepro_storage::{ConnectionStore, QueryHistory, StoragePaths};
use tablepro_sync::adapters::approval::Queue;
use tablepro_sync::adapters::library;
use tablepro_sync::api::RecordAdapter;
use tablepro_sync::cloudkit::fetch::{Categories, FetchReport, Fetcher};
use tablepro_sync::cloudkit::modify::{PushReport, Pusher, Waits};
use tablepro_sync::engine::{Adapters, Clock, StopSignal};
use tempfile::TempDir;
use uuid::Uuid;

use crate::support::{A, B, C, D, Rig};

struct Shelf {
    rig: Rig,
    _dir: TempDir,
    store: ConnectionStore,
    history: QueryHistory,
}

impl Shelf {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
        Self {
            rig: Rig::new().await,
            store: ConnectionStore::new(&paths),
            history: QueryHistory::open(&paths).await.unwrap(),
            _dir: dir,
        }
    }

    fn adapters(&self) -> Vec<Arc<dyn RecordAdapter>> {
        library::adapters(&self.store, Some(&self.history), library::DriverNames::Mac)
    }

    fn fetcher<'a>(&'a self, adapters: &'a [Arc<dyn RecordAdapter>]) -> Fetcher<'a> {
        Fetcher::new(
            self.rig.cloud.as_ref(),
            self.rig.state.as_ref(),
            adapters,
            Categories::new(Kind::ALL),
        )
        .unwrap()
    }

    async fn fetch(&self) -> FetchReport {
        let adapters = self.adapters();
        self.fetcher(&adapters).fetch().await.unwrap()
    }

    async fn push(&self) -> PushReport {
        let adapters = self.adapters();
        let fetcher = self.fetcher(&adapters);
        let mut waits = Waits::default();
        Pusher::new(&fetcher, &StopSignal::new(), self.rig.clock.now_ms())
            .push(&mut waits, None)
            .await
            .unwrap()
    }

    async fn take_everything(&self) {
        let adapters = Adapters::new(self.adapters());
        let queue = Queue {
            state: &self.rig.state,
            adapters: &adapters,
        };
        for approval in queue.waiting().await.unwrap() {
            queue.decide(&approval.key, &approval.field, approval.digest, true).await.unwrap();
        }
    }
}

fn mac_tunnel() -> Value {
    json!({
        "agent_socket_path": "", "auth_method": "SSH Agent", "enabled": true, "host": "bastion",
        "jump_hosts": [{"auth_method": "SSH Agent", "host": "edge", "id": "9E5B6C0B-1C11-4C5B-9C8B-8E3C2C1A0B01",
            "private_key_path": "", "username": "a"}],
        "port": 22, "private_key_path": "", "remote_file_access": "readOnlyCopy", "remote_file_path": "",
        "totp_algorithm": "SHA1", "totp_digits": 6, "totp_mode": "none", "totp_period": 30, "username": "ops",
    })
}

fn mac_connection() -> Value {
    json!({
        "name": "Shop", "type": "PostgreSQL", "host": "db.internal", "port": 5432, "database": "shop",
        "username": "app", "color": "Blue", "safe_mode_level": "alertFull", "sort_order": 3, "is_favorite": true,
        "group_id": B, "tag_ids": [C], "ai_policy": "askEachTime", "startup_commands": "SET search_path TO shop",
        "ssh_config": mac_tunnel(),
        "ssl_config": {"ca_certificate_path": "", "client_certificate_path": "", "client_key_path": "",
            "mode": "Preferred"},
        "schema_version": 1,
    })
}

// Every kind a Mac writes, as it writes it.
fn save_mac_library(rig: &Rig) {
    rig.save_elsewhere(Kind::Connection, A, &mac_connection());
    rig.save_elsewhere(
        Kind::Group,
        B,
        &json!({"name": "Work", "color": "None", "sort_order": 0, "schema_version": 1}),
    );
    rig.save_elsewhere(
        Kind::Tag,
        C,
        &json!({"name": "prod", "color": "Red", "is_preset": false, "schema_version": 1}),
    );
    rig.save_elsewhere(
        Kind::SshProfile,
        D,
        &json!({
            "name": "edge", "host": "edge.example.com", "username": "", "auth_method": "Password",
            "private_key_path": "", "agent_socket_path": "", "totp_mode": "none", "totp_algorithm": "SHA1",
            "totp_digits": 6, "totp_period": 30, "schema_version": 1,
        }),
    );
    rig.save_elsewhere(
        Kind::CredentialProfile,
        B,
        &json!({"name": "ops", "username": "ops", "password_mode": "stored", "sort_order": 0, "schema_version": 1}),
    );
    rig.save_elsewhere(
        Kind::TableFolder,
        D,
        &json!({"connection_id": A, "database": "shop", "name": "Billing", "created_at": 1_000, "updated_at": 2_000,
            "schema_version": 1}),
    );
    let item = table_folder_item(Uuid::parse_str(A).unwrap(), "shop", None, "orders");
    rig.save_elsewhere(
        Kind::TableFolderItem,
        &item,
        &json!({"connection_id": A, "database": "shop", "name": "orders", "folder_id": D, "schema_version": 1}),
    );
}

#[tokio::test]
async fn a_mac_library_reads_into_the_stores_and_a_push_after_it_sends_nothing() {
    let shelf = Shelf::new().await;
    save_mac_library(&shelf.rig);

    shelf.fetch().await;
    shelf.take_everything().await;
    shelf.fetch().await;
    let pushed = shelf.push().await;
    let list = shelf.store.list_blocking().unwrap();
    let folders = shelf.history.table_folders().contents().await.unwrap();

    assert_eq!(pushed.queued, 0, "{pushed:?}");
    assert_eq!(list.connections.len(), 1);
    assert_eq!(list.connections[0].name, "Shop");
    assert_eq!(
        list.connections[0].ssh.as_ref().map(|ssh| ssh.host.as_str()),
        Some("bastion")
    );
    assert!(list.is_favorite(list.connections[0].id));
    assert_eq!((list.groups.len(), list.tags.len()), (1, 1));
    assert_eq!((list.ssh_profiles.len(), list.credential_profiles.len()), (1, 1));
    assert_eq!((folders.folders.len(), folders.items.len()), (1, 1));
}

#[tokio::test]
async fn a_copy_an_ios_build_wrote_reads_in_and_sends_nothing_back() {
    let shelf = Shelf::new().await;
    let ios = json!({
        "name": "Orders", "type": "MySQL", "host": "db", "port": 3306, "database": "shop", "username": "app",
        "color": "Red", "safe_mode_level": "off", "sort_order": 0, "is_favorite": false, "schema_version": 1,
        "ssl_config": {"ca_certificate_path": "", "client_certificate_path": "", "client_key_path": "",
            "mode": "Disabled"},
    });
    shelf.rig.save_elsewhere(Kind::Connection, A, &ios);

    shelf.fetch().await;
    shelf.take_everything().await;
    shelf.fetch().await;
    let pushed = shelf.push().await;

    assert_eq!(shelf.store.list_blocking().unwrap().connections.len(), 1);
    assert_eq!(pushed.queued, 0, "{pushed:?}");
    assert_eq!(
        shelf.rig.zone_fields(Kind::Connection, A).unwrap()["safe_mode_level"],
        json!("off")
    );
}

#[tokio::test]
async fn a_rename_goes_up_as_the_one_member_it_changed() {
    let shelf = Shelf::new().await;
    save_mac_library(&shelf.rig);
    shelf.fetch().await;
    shelf.take_everything().await;
    shelf.fetch().await;
    let before = shelf.rig.zone_fields(Kind::Connection, A).unwrap();
    let id = shelf.store.list_blocking().unwrap().connections[0].id;

    shelf
        .store
        .update_blocking(id, |saved| saved.name = "Shop 2".to_owned())
        .unwrap();
    let pushed = shelf.push().await;
    let mut after = shelf.rig.zone_fields(Kind::Connection, A).unwrap();

    assert_eq!(pushed.queued, 1, "{pushed:?}");
    assert_eq!(after["name"], json!("Shop 2"));
    after["name"] = before["name"].clone();
    assert_eq!(after, before);
}

#[tokio::test]
async fn a_folder_without_its_connection_is_held_by_id_and_the_zone_keeps_it() {
    let shelf = Shelf::new().await;
    shelf.rig.save_elsewhere(
        Kind::TableFolder,
        D,
        &json!({"database": "shop", "name": "Billing", "created_at": 1_000, "updated_at": 2_000, "schema_version": 1}),
    );

    shelf.fetch().await;
    let pushed = shelf.push().await;

    assert!(
        shelf
            .history
            .table_folders()
            .contents()
            .await
            .unwrap()
            .folders
            .is_empty()
    );
    assert_eq!(pushed.queued, 0, "{pushed:?}");
    assert!(shelf.rig.zone_fields(Kind::TableFolder, D).is_some());
}
