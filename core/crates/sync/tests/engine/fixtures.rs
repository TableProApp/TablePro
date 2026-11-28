// The shared merge fixtures of `tablepro-records` on the TablePro Sync path (0054, Verification; 0051, Tests, Merge):
// one device holds the base, the other side's copy goes up from a second device, this device edits its own, and the
// next pass leaves the store holding what the field merge gives once the person approved what waited.

use std::sync::Arc;

use serde_json::Value;
use tablepro_keys::encoding::TeamId;
use tablepro_records::Kind;
use tablepro_records::record_id::favourite_table;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::scopes::Role;
use tablepro_sync_testing::FakeServer;
use uuid::Uuid;

use super::harness::{Device, DeviceBuilder, MemoryAdapter, StoreFile, account, id};

fn cases() -> Vec<Value> {
    let cases: Value = serde_json::from_str(include_str!("../../../records/fixtures/merge.json")).unwrap();
    cases.as_array().unwrap().clone()
}

fn id_for(kind: Kind, case: &Value) -> String {
    match kind {
        Kind::FavouriteTable => favourite_table(Uuid::nil(), Some("shop"), None, "orders").id,
        Kind::MacosSettings => ["local", "base", "server"]
            .iter()
            .find_map(|side| case[side]["category"].as_str())
            .unwrap()
            .to_owned(),
        Kind::LibraryFolder | Kind::LibraryQuery => "client-1".to_owned(),
        _ => id(1),
    }
}

struct Side {
    device: Device,
    store: Arc<MemoryAdapter>,
}

async fn side(server: &Arc<FakeServer>, row: &str, kind: Kind, scope: ScopeName) -> Side {
    if kind == Kind::Connection {
        let device = Device::new(server, row).await;
        let store = Arc::clone(&device.connections);
        return Side { device, store };
    }
    let store = MemoryAdapter::new(kind, "store", StoreFile::new());
    let device = DeviceBuilder::new(server, row)
        .adapter(scope, Arc::clone(&store))
        .build()
        .await;
    Side { device, store }
}

async fn approve_everything(device: &Device) {
    for _ in 0..8 {
        let waiting = device.sync.approvals().await.unwrap();
        if waiting.is_empty() {
            return;
        }
        for record in waiting {
            device
                .sync
                .decide_record_approval(record.key, record.digest, true)
                .await
                .unwrap();
        }
    }
}

// What a store holds of a record: a member its model has no place for rides on the base instead.
fn as_held(kind: Kind, record: &Value) -> Value {
    let mut out = record.clone();
    if let Value::Object(members) = &mut out {
        members.retain(|name, _| tablepro_sync::adapters::carry::holds(kind, &format!("/{name}")));
    }
    out
}

fn copy(case: &Value, name: &str) -> Option<Value> {
    Some(case[name].clone()).filter(|copy| !copy.is_null())
}

#[tokio::test]
async fn the_shared_merge_fixtures_land_in_the_store_through_a_pull() {
    let cases = cases();
    assert!(cases.len() >= 15);
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let kind = Kind::parse(case["kind"].as_str().unwrap()).unwrap().unwrap();
        let server = FakeServer::new();
        let team = TeamId(Uuid::from_u128(0x0191_0000_0000_7000_8000_0000_0000_00BB));
        let scope = if case["mode"] == "team" {
            server.add_team(team, &[(account(), Role::Owner)]);
            ScopeName::Team(team)
        } else {
            ScopeName::Personal
        };
        let record = id_for(kind, case);
        let theirs = side(&server, "dev_theirs", kind, scope).await;
        let mine = side(&server, "dev_mine", kind, scope).await;
        if let Some(base) = copy(case, "base") {
            theirs.store.put(&record, base);
            theirs.device.sync().await;
            mine.device.sync().await;
            approve_everything(&mine.device).await;
        }

        match copy(case, "server") {
            Some(server_copy) => theirs.store.put(&record, server_copy),
            None => theirs.store.remove(&record),
        }
        theirs.device.sync().await;
        match copy(case, "local") {
            Some(local) => mine.store.put(&record, local),
            None => mine.store.remove(&record),
        }
        mine.device.sync().await;
        approve_everything(&mine.device).await;

        let held = mine.store.get(&record);
        let merged = &case["merged"];
        let conflicts = mine.device.sync.conflicts().await.unwrap();
        if merged == "deleted" {
            assert_eq!(held, None, "{name}");
        } else if let Some(record) = merged.get("record") {
            assert_eq!(held, Some(as_held(kind, record)), "{name}");
            assert!(conflicts.is_empty(), "{name}");
        } else if let Some(contested) = merged.get("contested") {
            assert_eq!(held, Some(as_held(kind, &contested["record"])), "{name}");
            let fields: Vec<Value> = conflicts[0]
                .fields
                .iter()
                .map(|field| Value::from(field.as_str()))
                .collect();
            assert_eq!(Value::from(fields), contested["fields"], "{name}");
        } else if let Some(contested) = merged.get("deletion_contested") {
            let kept_here = contested["deleted_here"] == false;
            assert_eq!(held.is_some(), kept_here, "{name}");
            assert_eq!(conflicts.len(), 1, "{name}");
        } else {
            panic!("{name}: an outcome this test does not read");
        }
    }
}
