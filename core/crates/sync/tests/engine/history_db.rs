// The kinds of the core's `history.db` through their adapters over the real store: saved queries and folders, with
// the keyword and name settlement every device applies the same way (0052, Collisions), and the query history with
// its window, paging back, prunes and the person's deletions (0051, Pull, Tombstones; 0054, Providers, History).

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use tablepro_storage::query_history::{NewEntry, Outcome};
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{QueryHistory, SavedQueryFolder, SavedQueryWrite, StoragePaths};
use tablepro_sync::adapters::history::HistoryAdapter;
use tablepro_sync::adapters::saved_queries::SavedQueryAdapter;
use tablepro_sync::adapters::settings::ConnectionStanding;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::state::Standing;
use tablepro_sync::api::transport::DeletedReason;
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::ScopeOwner;
use uuid::Uuid;

use super::harness::{ACCOUNT, Device, DeviceBuilder, account, personal, write};

const SHOP: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const SCRATCH: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";
const REPORTS: &str = "380CB783-4B26-48F3-8F84-1468967A9FA3";

struct LocalOnly(HashSet<Uuid>);

impl ConnectionStanding for LocalOnly {
    fn standing(&self, connection: Uuid) -> Standing {
        if self.0.contains(&connection) {
            Standing::LocalOnly
        } else {
            Standing::Syncs
        }
    }
}

fn uuid(text: &str) -> Uuid {
    Uuid::parse_str(text).unwrap()
}

fn query_id(n: u8) -> Uuid {
    uuid(&format!("E9BFE8BE-525F-4F8A-9E9C-F795A5F09A{n:02X}"))
}

fn wire_id(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

async fn device(server: &Arc<FakeServer>, row: &str, dir: &Path) -> (Device, QueryHistory) {
    let history = QueryHistory::open(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
        .await
        .unwrap();
    let mut builder = DeviceBuilder::new(server, row).extra_adapter(Arc::new(HistoryAdapter::new(
        history.clone(),
        Arc::new(LocalOnly(HashSet::from([uuid(SCRATCH)]))),
    )));
    for adapter in SavedQueryAdapter::all(&history) {
        builder = builder.extra_adapter(adapter);
    }
    (builder.build().await, history)
}

// The service takes a history entry only under the newest HK version it holds.
async fn history_key(device: &Device) {
    let version = format!("{ACCOUNT}/history/1");
    device
        .push_raw(
            ScopeName::Personal,
            vec![write("key.version", &version, None, json!({"suite": "tp1"}))],
        )
        .await;
}

fn at(millis: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_millis(millis)
}

fn query(id: Uuid, name: &str, keyword: Option<&str>, created_ms: u64) -> SavedQuery {
    SavedQuery {
        id,
        name: name.to_owned(),
        query: format!("SELECT '{name}'"),
        connection_id: Some(uuid(SHOP)),
        connection_name: "shop".to_owned(),
        keyword: keyword.map(str::to_owned),
        folder_id: None,
        order: 0,
        created_at: at(created_ms),
        updated_at: at(created_ms),
    }
}

async fn save(history: &QueryHistory, queries: Vec<SavedQuery>, folders: Vec<SavedQueryFolder>) {
    history
        .saved_queries()
        .write(&SavedQueryWrite {
            queries,
            folders,
            ..SavedQueryWrite::default()
        })
        .await
        .unwrap();
}

async fn held(history: &QueryHistory, id: Uuid) -> Option<SavedQuery> {
    history
        .saved_queries()
        .contents()
        .await
        .unwrap()
        .queries
        .into_iter()
        .find(|query| query.id == id)
}

fn on_server(server: &FakeServer, id: Uuid) -> Option<Value> {
    server
        .stored(personal(), "saved_query", &wire_id(id))
        .and_then(|record| record.fields)
}

#[tokio::test]
async fn two_devices_converge_on_saved_queries_and_folders_held_in_the_core_store() {
    let server = FakeServer::new();
    let (mac_dir, mini_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mac, mac_history) = device(&server, "dev_mac", mac_dir.path()).await;
    let (mini, mini_history) = device(&server, "dev_mini", mini_dir.path()).await;
    let reports = SavedQueryFolder {
        id: uuid(REPORTS),
        connection_id: Some(uuid(SHOP)),
        name: "Reports".to_owned(),
        parent_id: None,
        order: 0,
        created_at: at(1_000),
        updated_at: at(1_000),
    };
    let daily = SavedQuery {
        folder_id: Some(uuid(REPORTS)),
        ..query(query_id(1), "Daily", Some("daily"), 1_767_225_600_123)
    };
    save(&mac_history, vec![daily.clone()], vec![reports]).await;

    mac.sync().await;
    mini.sync().await;
    let arrived = held(&mini_history, query_id(1)).await.unwrap();
    let mut renamed = arrived.clone();
    renamed.name = "Daily revenue".to_owned();
    save(&mini_history, vec![renamed], Vec::new()).await;
    let mut unfiled = daily.clone();
    unfiled.folder_id = None;
    mac_history
        .saved_queries()
        .write(&SavedQueryWrite {
            queries: vec![unfiled],
            removed_folders: vec![uuid(REPORTS)],
            ..SavedQueryWrite::default()
        })
        .await
        .unwrap();
    mac.sync().await;
    mini.sync().await;
    mac.sync().await;

    assert_eq!(
        (arrived.folder_id, arrived.keyword.as_deref(), arrived.created_at),
        (Some(uuid(REPORTS)), Some("daily"), daily.created_at)
    );
    for history in [&mac_history, &mini_history] {
        let contents = history.saved_queries().contents().await.unwrap();
        assert!(contents.folders.is_empty());
        assert_eq!(contents.queries.len(), 1);
        assert_eq!(contents.queries[0].name, "Daily revenue");
        assert_eq!(contents.queries[0].folder_id, None);
    }
    assert!(
        server
            .stored(personal(), "saved_query_folder", REPORTS)
            .unwrap()
            .deleted
            .is_some()
    );
}

#[tokio::test]
async fn every_device_settles_a_contested_keyword_and_name_on_the_query_created_first() {
    let server = FakeServer::new();
    let (mac_dir, mini_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mac, mac_history) = device(&server, "dev_mac", mac_dir.path()).await;
    let (mini, mini_history) = device(&server, "dev_mini", mini_dir.path()).await;
    // Each device gives the keyword and the name to a query of its own; the mini's was created first but goes up last.
    save(
        &mac_history,
        vec![query(query_id(1), "Revenue", Some("rev"), 2_000)],
        Vec::new(),
    )
    .await;
    save(
        &mini_history,
        vec![query(query_id(2), "Revenue", Some("rev"), 1_000)],
        Vec::new(),
    )
    .await;

    mac.sync().await;
    mini.sync().await;
    let released = on_server(&server, query_id(1)).unwrap();
    mac.sync().await;
    let settled = [mac.sync().await.pushed, mini.sync().await.pushed];

    assert_eq!(released.get("keyword"), None, "the mini's pass sent the release");
    assert_eq!(released["name"], json!("Revenue (2)"));
    assert_eq!(on_server(&server, query_id(2)).unwrap()["keyword"], json!("rev"));
    for history in [&mac_history, &mini_history] {
        let (later, first) = (
            held(history, query_id(1)).await.unwrap(),
            held(history, query_id(2)).await.unwrap(),
        );
        assert_eq!((later.keyword, later.name.as_str()), (None, "Revenue (2)"));
        assert_eq!(
            (first.keyword.as_deref(), first.name.as_str()),
            (Some("rev"), "Revenue")
        );
    }
    assert_eq!(
        settled,
        [0, 0],
        "both devices wrote the same values, so nothing goes back and forth"
    );
}

fn run(connection: &str, query: &str, executed_ms: u64) -> NewEntry {
    NewEntry {
        record_id: Uuid::new_v4(),
        query: query.to_owned(),
        driver_id: "PostgreSQL".to_owned(),
        connection_id: uuid(connection),
        connection_name: "shop".to_owned(),
        executed_at: at(executed_ms),
        duration_ms: Some(4),
        rows_affected: Some(1),
        outcome: Outcome::Success,
    }
}

fn on_history(server: &FakeServer, id: Uuid) -> Option<(bool, Option<DeletedReason>)> {
    server
        .stored(ScopeOwner::History(account()), "history_entry", &wire_id(id))
        .map(|record| (record.fields.is_some(), record.deleted))
}

async fn ids(history: &QueryHistory) -> HashSet<Uuid> {
    history
        .entries()
        .await
        .unwrap()
        .into_iter()
        .map(|entry| entry.record_id)
        .collect()
}

#[tokio::test]
async fn history_goes_up_sealed_a_prune_pushes_nothing_and_the_person_s_deletion_reaches_the_other_device() {
    let server = FakeServer::new();
    let (mac_dir, mini_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mac, mac_history) = device(&server, "dev_mac", mac_dir.path()).await;
    let (mini, mini_history) = device(&server, "dev_mini", mini_dir.path()).await;
    history_key(&mac).await;
    let now = u64::try_from(
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap();
    let (old, kept, scratch) = (
        run(SHOP, "SELECT old", 1_000_000),
        run(SHOP, "SELECT kept", now),
        run(SCRATCH, "SELECT scratch", now),
    );
    for entry in [&old, &kept, &scratch] {
        mac_history.record(entry.clone()).await.unwrap();
    }

    mac.sync().await;
    mini.sync().await;
    let pulled = ids(&mini_history).await;
    mac_history.prune(30).await.unwrap();
    mac.sync().await;
    let kept_row = mac_history
        .entries()
        .await
        .unwrap()
        .into_iter()
        .find(|entry| entry.record_id == kept.record_id)
        .unwrap()
        .id;
    mac_history.delete_returning(&[kept_row]).await.unwrap();
    mac.sync().await;
    mini.sync().await;

    assert_eq!(pulled, HashSet::from([old.record_id, kept.record_id]));
    assert_eq!(
        on_history(&server, scratch.record_id),
        None,
        "a Local only connection's runs stay here"
    );
    assert_eq!(
        on_history(&server, old.record_id),
        Some((true, None)),
        "a prune deletes nothing"
    );
    assert_eq!(
        on_history(&server, kept.record_id),
        Some((false, Some(DeletedReason::User)))
    );
    assert!(
        mac_history.tombstones().await.unwrap().is_empty(),
        "the pushed deletion lets its tombstone go"
    );
    assert_eq!(ids(&mini_history).await, HashSet::from([old.record_id]));
    assert!(mini_history.tombstones().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_device_takes_its_window_of_history_newest_first_and_pages_back_into_the_store() {
    let server = FakeServer::new();
    let (mac_dir, mini_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mac, mac_history) = device(&server, "dev_mac", mac_dir.path()).await;
    history_key(&mac).await;
    let runs: Vec<NewEntry> = (1..=3)
        .map(|n| run(SHOP, &format!("SELECT {n}"), 1_767_225_600_000 + n * 1_000))
        .collect();
    for entry in &runs {
        mac_history.record(entry.clone()).await.unwrap();
        mac.sync().await;
    }
    let (mini, mini_history) = device(&server, "dev_mini", mini_dir.path()).await;
    mini.sync.set_history_window(Some(1));

    mini.sync().await;
    let window = ids(&mini_history).await;
    let mut more = Vec::new();
    for _ in 0..10 {
        let older = mini.sync.load_older_history().await.unwrap();
        more.push(older);
        if !older {
            break;
        }
    }

    assert_eq!(window, HashSet::from([runs[2].record_id]));
    assert_eq!(
        ids(&mini_history).await,
        runs.iter().map(|entry| entry.record_id).collect::<HashSet<_>>()
    );
    let paged = mini_history
        .entries()
        .await
        .unwrap()
        .into_iter()
        .find(|entry| entry.record_id == runs[0].record_id)
        .unwrap();
    assert_eq!((paged.query.as_str(), paged.rows_affected), ("SELECT 1", Some(1)));
    assert_eq!(more.last(), Some(&false));
}

#[tokio::test]
async fn a_run_an_apple_app_recorded_with_a_password_in_it_never_reaches_the_server() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let (mac, mac_history) = device(&server, "dev_mac", dir.path()).await;
    history_key(&mac).await;
    let secret = NewEntry {
        driver_id: "MySQL".to_owned(),
        ..run(SHOP, "CREATE USER 'app'@'%' IDENTIFIED BY 'hunter2'", 1_767_225_600_000)
    };
    let plain = NewEntry {
        driver_id: "MySQL".to_owned(),
        ..run(SHOP, "SELECT * FROM orders", 1_767_225_601_000)
    };
    mac_history.put(&[secret.clone(), plain.clone()]).await.unwrap();

    mac.sync().await;

    assert_eq!(on_history(&server, secret.record_id), None);
    assert_eq!(on_history(&server, plain.record_id), Some((true, None)));
    assert_eq!(
        ids(&mac_history).await.len(),
        2,
        "the device keeps its own history whole"
    );
}
