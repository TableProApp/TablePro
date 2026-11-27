// The approval queue as a review lists and decides it (0044, Fields a pull applies only with approval; 0066, Rules):
// one entry per record with its waiting values, decisions per value and per record, the status while values wait, and
// the signal the app refreshes on. The devices keep their state in the on-disk file, as the apps do.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_sync::api::control::{SyncControl, SyncPhase};
use tablepro_sync::api::ids::{DeviceRowId, RecordKey, ScopeName};
use tablepro_sync::api::state::{HeldReason, Row, RowRange, Table};
use tablepro_sync::engine::EngineEvents;
use tablepro_sync_testing::{FakeDeviceStore, FakeServer};

use super::harness::{Device, DeviceBuilder, KeyLog, id, open_on_disk, personal};

fn key(record: &str) -> RecordKey {
    RecordKey::new(ScopeName::Personal, Kind::Connection, record)
}

fn stored(server: &FakeServer, record: &str) -> Option<Value> {
    server
        .stored(personal(), "connection", record)
        .and_then(|record| record.fields)
}

fn prod() -> Value {
    json!({
        "name": "Prod",
        "type": "PostgreSQL",
        "host": "db.example.com",
        "port": 5432,
        "database": "shop",
        "username": "app",
        "startup_commands": "SET search_path = shop"
    })
}

fn staging() -> Value {
    json!({"name": "Staging", "type": "SQLite", "database": "/data/staging.sqlite"})
}

#[derive(Default)]
struct Heard {
    approvals: AtomicUsize,
}

impl EngineEvents for Heard {
    fn status_changed(&self) {}

    fn keys_changed(&self) {}

    fn approvals_changed(&self) {
        self.approvals.fetch_add(1, Ordering::SeqCst);
    }
}

impl Heard {
    fn approvals(&self) -> usize {
        self.approvals.load(Ordering::SeqCst)
    }
}

// A device whose state file is on disk, as the apps keep it.
async fn on_disk(server: &Arc<FakeServer>, row: &str, dir: &tempfile::TempDir) -> Device {
    let device_store = Arc::new(FakeDeviceStore::new());
    DeviceBuilder::new(server, row)
        .state(open_on_disk(dir.path(), row, &device_store).await)
        .build()
        .await
}

async fn held(device: &Device) -> Vec<(String, HeldReason)> {
    device
        .rows(RowRange::Table(Table::Held))
        .await
        .into_iter()
        .filter_map(|row| match row {
            Row::Held(row) => Some((row.key.record_id, row.reason)),
            _ => None,
        })
        .collect()
}

// E2E F14: a Mac approved after its first pull holds another device's connections whole until the person approves
// them, and the status says so instead of reading as up to date.
#[tokio::test]
async fn a_device_approved_after_its_first_pull_lists_the_connections_it_holds_and_takes_them_once_approved() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), prod());
    mac.connections.put(&id(2), staging());
    mac.sync().await;
    let dir = tempfile::tempdir().unwrap();
    let device_store = Arc::new(FakeDeviceStore::new());
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .state(open_on_disk(dir.path(), "dev_mini", &device_store).await)
        .keys(Arc::new(KeyLog::waiting_for_approval()))
        .unapproved()
        .build()
        .await;

    mini.sync().await;
    let before = (held(&mini).await, mini.connections.get(&id(1)));
    server.approve(&DeviceRowId("dev_mini".to_owned()), mini.seed.public().unwrap().0);
    mini.keys.approved();
    mini.sync().await;
    let status = mini.sync.status();
    let listed = mini.sync.approvals().await.unwrap();

    assert_eq!(before, (Vec::new(), None));
    assert_eq!(
        held(&mini).await,
        [
            (id(1), HeldReason::AwaitingApproval),
            (id(2), HeldReason::AwaitingApproval)
        ]
    );
    assert_eq!((status.waiting_approvals, status.phase), (2, SyncPhase::NeedsApproval));
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].key, key(&id(1)));
    assert_eq!(listed[0].name.as_deref(), Some("Prod"));
    assert!(listed[0].new_record);
    let mut fields: Vec<(&str, &Value)> = listed[0]
        .fields
        .iter()
        .map(|field| (field.field.as_str(), &field.pulled))
        .collect();
    fields.sort_by_key(|(field, _)| *field);
    assert_eq!(
        fields,
        [
            ("/database", &json!("shop")),
            ("/host", &json!("db.example.com")),
            ("/port", &json!(5432)),
            ("/startup_commands", &json!("SET search_path = shop")),
            ("/type", &json!("PostgreSQL")),
            ("/username", &json!("app")),
        ]
    );
    assert!(listed[0].fields.iter().all(|field| field.current.is_none()));
    assert_eq!(listed[1].name.as_deref(), Some("Staging"));

    for record in listed {
        mini.sync
            .decide_record_approval(record.key, record.digest, true)
            .await
            .unwrap();
    }
    let status = mini.sync.status();
    let pass = mini.sync().await;

    assert_eq!(mini.connections.get(&id(1)), Some(prod()));
    assert_eq!(mini.connections.get(&id(2)), Some(staging()));
    assert!(held(&mini).await.is_empty());
    assert!(mini.sync.approvals().await.unwrap().is_empty());
    assert_eq!((status.waiting_approvals, status.phase), (0, SyncPhase::Idle));
    assert_eq!(pass.pushed, 0);
    assert_eq!(stored(&server, &id(1)), Some(prod()));
}

#[tokio::test]
async fn a_changed_host_lists_the_device_s_value_beside_the_pulled_one_and_lands_once_approved() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = on_disk(&server, "dev_mini", &dir).await;
    mac.connections.put(&id(1), prod());
    mac.sync().await;
    mini.sync().await;
    mini.decide_record(&id(1), true).await;
    let mut moved = prod();
    moved["host"] = json!("db2.example.com");
    moved["name"] = json!("Prod (moved)");
    mac.connections.put(&id(1), moved.clone());
    mac.sync().await;

    mini.sync().await;
    let listed = mini.sync.approvals().await.unwrap();
    let kept = mini.connections.get(&id(1));
    mini.sync
        .decide_record_approval(key(&id(1)), listed[0].digest, true)
        .await
        .unwrap();

    let mut renamed = prod();
    renamed["name"] = json!("Prod (moved)");
    assert_eq!(kept, Some(renamed));
    assert_eq!(listed.len(), 1);
    assert!(!listed[0].new_record);
    assert_eq!(listed[0].name.as_deref(), Some("Prod (moved)"));
    assert_eq!(listed[0].fields.len(), 1);
    assert_eq!(listed[0].fields[0].field, "/host");
    assert_eq!(listed[0].fields[0].current, Some(json!("db.example.com")));
    assert_eq!(listed[0].fields[0].pulled, json!("db2.example.com"));
    assert_eq!(mini.connections.get(&id(1)), Some(moved));
    assert!(mini.sync.approvals().await.unwrap().is_empty());
}

// A value approved lands; one refused stays the device's own, is never sent back over the pulled one, and is not asked
// again while the pull brings the same value.
#[tokio::test]
async fn a_mixed_decision_takes_the_approved_value_and_keeps_the_refused_one_without_asking_again() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = on_disk(&server, "dev_mini", &dir).await;
    mac.connections.put(&id(1), prod());
    mac.sync().await;
    mini.sync().await;
    mini.decide_record(&id(1), true).await;
    let mut changed = prod();
    changed["host"] = json!("db2.example.com");
    changed["startup_commands"] = json!("DROP TABLE orders");
    mac.connections.put(&id(1), changed.clone());
    mac.sync().await;
    mini.sync().await;

    mini.decide(key(&id(1)), "/host", true).await.unwrap();
    mini.decide(key(&id(1)), "/startup_commands", false).await.unwrap();
    let status = mini.sync.status();
    mini.sync().await;
    mini.sync().await;

    let mut kept = prod();
    kept["host"] = json!("db2.example.com");
    assert_eq!(mini.connections.get(&id(1)), Some(kept));
    assert_eq!((status.waiting_approvals, status.phase), (0, SyncPhase::Idle));
    assert!(mini.sync.approvals().await.unwrap().is_empty());
    assert_eq!(stored(&server, &id(1)), Some(changed));
}

// After a refusal and after an approval alike, a pull that changes the value again asks about the new value, showing
// what the device holds then.
#[tokio::test]
async fn a_later_pull_that_changes_a_decided_value_asks_again() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = on_disk(&server, "dev_mini", &dir).await;
    let reports = json!({"name": "Reports", "host": "reports.example.com"});
    mac.connections.put(&id(1), prod());
    mac.connections.put(&id(2), reports.clone());
    mac.sync().await;
    mini.sync().await;
    mini.decide_record(&id(1), true).await;
    mini.decide_record(&id(2), true).await;
    let at = |fields: &Value, host: &str| {
        let mut fields = fields.clone();
        fields["host"] = json!(host);
        fields
    };
    mac.connections.put(&id(1), at(&prod(), "second.example.com"));
    mac.connections.put(&id(2), at(&reports, "second.example.com"));
    mac.sync().await;
    mini.sync().await;
    mini.decide(key(&id(1)), "/host", false).await.unwrap();
    mini.decide(key(&id(2)), "/host", true).await.unwrap();
    mac.connections.put(&id(1), at(&prod(), "third.example.com"));
    mac.connections.put(&id(2), at(&reports, "third.example.com"));
    mac.sync().await;

    mini.sync().await;
    let asked: Vec<(RecordKey, Option<Value>, Value)> = mini
        .waiting()
        .await
        .into_iter()
        .map(|value| (value.key, value.current, value.pulled))
        .collect();

    assert_eq!(
        asked,
        [
            (key(&id(1)), Some(json!("db.example.com")), json!("third.example.com")),
            (
                key(&id(2)),
                Some(json!("second.example.com")),
                json!("third.example.com")
            ),
        ]
    );
    assert_eq!(mini.sync.status().waiting_approvals, 2);
}

// A refusal of a record new to the device keeps the whole record off it, the only value it had of it, and the same
// values are not asked again. A pull that brings another value asks about the record as it is now, every value of it
// again, since it lands only whole.
#[tokio::test]
async fn a_refused_new_record_stays_off_the_device_until_a_pull_brings_another_value() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = on_disk(&server, "dev_mini", &dir).await;
    mac.connections.put(&id(1), prod());
    mac.sync().await;
    mini.sync().await;

    mini.decide_record(&id(1), false).await;
    mini.sync().await;
    let after_refusal = (
        mini.connections.get(&id(1)),
        mini.sync.approvals().await.unwrap().len(),
        mini.sync.status().phase,
    );
    let mut moved = prod();
    moved["host"] = json!("db2.example.com");
    mac.connections.put(&id(1), moved.clone());
    mac.sync().await;
    mini.sync().await;
    let asked = mini.sync.approvals().await.unwrap();
    mini.decide_record(&id(1), true).await;

    assert_eq!(after_refusal, (None, 0, SyncPhase::Idle));
    assert_eq!(asked.len(), 1);
    assert!(asked[0].new_record);
    assert_eq!(asked[0].fields.len(), 6);
    assert!(
        asked[0]
            .fields
            .iter()
            .any(|field| field.field == "/host" && field.pulled == json!("db2.example.com"))
    );
    assert_eq!(mini.connections.get(&id(1)), Some(moved));
    assert!(held(&mini).await.is_empty());
}

// The record's digest names every value listed: a pull that changed one since decides nothing, and the person sees the
// record as it is now.
#[tokio::test]
async fn a_record_decision_on_values_a_pull_changed_since_decides_nothing() {
    let server = FakeServer::new();
    let dir = tempfile::tempdir().unwrap();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = on_disk(&server, "dev_mini", &dir).await;
    mac.connections.put(&id(1), prod());
    mac.sync().await;
    mini.sync().await;
    let shown = mini.sync.approvals().await.unwrap();
    let mut moved = prod();
    moved["host"] = json!("attacker.example.com");
    mac.connections.put(&id(1), moved);
    mac.sync().await;
    mini.sync().await;

    let answered = mini
        .sync
        .decide_record_approval(key(&id(1)), shown[0].digest, true)
        .await;

    assert_eq!(answered.unwrap_err().code(), "sync.changed");
    assert_eq!(mini.connections.get(&id(1)), None);
    let listed = mini.sync.approvals().await.unwrap();
    assert_ne!(listed[0].digest, shown[0].digest);
    assert!(
        listed[0]
            .fields
            .iter()
            .any(|field| field.pulled == json!("attacker.example.com"))
    );
}

#[tokio::test]
async fn the_app_hears_when_values_arrive_and_when_they_are_decided_and_not_on_a_pass_that_changes_neither() {
    let server = FakeServer::new();
    let heard = Arc::new(Heard::default());
    let mac = Device::new(&server, "dev_mac").await;
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .events(Arc::clone(&heard) as Arc<dyn EngineEvents>)
        .build()
        .await;
    mini.sync().await;
    let at_start = heard.approvals();
    mac.connections.put(&id(1), prod());
    mac.sync().await;

    mini.sync().await;
    let on_arrival = heard.approvals();
    mini.sync().await;
    let on_an_idle_pass = heard.approvals();
    mini.decide(key(&id(1)), "/host", true).await.unwrap();
    let on_one_decision = heard.approvals();
    mini.decide_record(&id(1), true).await;

    assert_eq!(at_start, 0);
    assert_eq!(on_arrival, 1);
    assert_eq!(on_an_idle_pass, 1);
    assert_eq!(on_one_decision, 2);
    assert_eq!(heard.approvals(), 3);
}
