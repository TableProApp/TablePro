use serde_json::{Value, json};
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::state::{Row, RowKey};
use tablepro_sync_testing::FakeServer;

use super::harness::{Device, id, personal};

fn named(name: &str, version: &str) -> Value {
    json!({"name": name, "host": version, "sort_order": 1})
}

fn stored(server: &FakeServer, record: &str) -> Option<Value> {
    server
        .stored(personal(), "connection", record)
        .and_then(|record| record.fields)
}

#[tokio::test]
async fn an_expired_cursor_takes_a_snapshot() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections.put(&id(1), named("A", "v1"));
    mac.sync().await;
    mini.sync().await;

    mac.connections.put(&id(1), named("A", "v2"));
    mac.sync().await;
    mini.wire.expire_next_cursor();
    mini.sync().await;

    assert_eq!(mini.connections.get(&id(1)), Some(named("A", "v2")));
}

#[tokio::test]
async fn after_a_restore_the_writes_the_server_lost_go_back_and_later_ones_merge() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections.put(&id(1), named("A", "v1"));
    mac.connections.put(&id(2), named("B", "v1"));
    mac.sync().await;
    mini.sync().await;
    let backup = server.backup();
    mac.connections.put(&id(1), named("A", "v2"));
    mac.connections.put(&id(3), named("C", "v1"));
    mac.sync().await;

    let epoch = server.restore(&backup);
    mini.connections.put(&id(2), named("B", "after the restore"));
    mini.sync().await;
    mac.sync().await;
    mini.sync().await;

    assert_eq!(stored(&server, &id(1)), Some(named("A", "v2")));
    assert_eq!(stored(&server, &id(3)), Some(named("C", "v1")));
    assert_eq!(mac.connections.get(&id(2)), Some(named("B", "after the restore")));
    assert_eq!(mini.connections.get(&id(1)), Some(named("A", "v2")));
    assert_eq!(mini.connections.get(&id(3)), Some(named("C", "v1")));
    assert_eq!(mac.keys.pushed_back_at(), vec![epoch]);
    let Some(Row::Scope(row)) = mac.row(RowKey::Scope(ScopeName::Personal)).await else {
        panic!("no scope row");
    };
    assert_eq!(row.epoch, Some(epoch));
    assert!(!row.refill);
    assert_eq!(row.lineage.last().map(|held| held.id), Some(epoch));
}

#[tokio::test]
async fn a_push_into_another_epoch_refills_before_it_goes_up_again() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), named("A", "v1"));
    mac.sync().await;

    mac.connections.put(&id(1), named("A", "v2"));
    mac.wire.new_epoch_before_push();
    let report = mac.sync().await;

    assert_eq!(report.pushed, 1);
    assert_eq!(stored(&server, &id(1)), Some(named("A", "v2")));
    assert_eq!(mac.keys.pushed_back_at(), vec![server.epoch()]);
    let Some(Row::Scope(row)) = mac.row(RowKey::Scope(ScopeName::Personal)).await else {
        panic!("no scope row");
    };
    assert_eq!(row.epoch, Some(server.epoch()));
}
