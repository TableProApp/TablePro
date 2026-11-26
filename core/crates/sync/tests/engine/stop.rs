use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::control::{SyncControl, SyncPhase};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::state::{Row, RowKey, RowRange, Table};
use tablepro_sync_testing::FakeServer;

use super::harness::{Device, DeviceBuilder, MemoryAdapter, StoreFile, connection, id};

// P1-M4: a provider stop that lands while a pull writes its stores ends the pass before the next store write, and the
// pull commits nothing after it.
#[tokio::test]
async fn a_stop_during_a_pull_ends_it_before_the_next_store_write_and_commits_nothing() {
    let server = FakeServer::new();
    let mac_tags = MemoryAdapter::new(Kind::Tag, "tags", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::Personal, Arc::clone(&mac_tags))
        .build()
        .await;
    mac.connections.put(&id(1), connection("Prod"));
    mac_tags.put(&id(2), json!({"name": "prod", "color": "Red"}));
    mac.sync().await;
    let tags = MemoryAdapter::new(Kind::Tag, "tags", StoreFile::new());
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .adapter(ScopeName::Personal, Arc::clone(&tags))
        .build()
        .await;
    let stop = mini.stop.clone();
    mini.connections.on_apply(move || stop.stop());

    let stopped = mini.pass().await;
    let bases = mini.rows(RowRange::Table(Table::Bases)).await;
    let row = mini.row(RowKey::Scope(ScopeName::Personal)).await;
    let phase = mini.sync.status().phase;
    mini.connections.on_apply(|| {});
    mini.stop.resume();
    mini.sync().await;

    assert_eq!(stopped.err(), Some(SyncError::Cancelled));
    assert_eq!(
        mini.connections.get(&id(1)),
        Some(connection("Prod")),
        "the write in progress finished"
    );
    assert_eq!(phase, SyncPhase::Off);
    assert!(bases.is_empty(), "the pull committed bases after the stop");
    assert!(matches!(row, Some(Row::Scope(row)) if row.cursor.is_none() && !row.caught_up));
    assert_eq!(tags.get(&id(2)), Some(json!({"name": "prod", "color": "Red"})));
    assert_eq!(tags.applies(), 1);
}

#[tokio::test]
async fn a_stopped_provider_makes_no_call() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.stop.stop();

    let stopped = mac.pass().await;

    assert_eq!(stopped.err(), Some(SyncError::Cancelled));
    assert_eq!(mac.wire.pulls.load(Ordering::SeqCst), 0);
    assert!(mac.wire.pushed().is_empty());
}
