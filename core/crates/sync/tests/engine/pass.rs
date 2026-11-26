use std::sync::Arc;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_sync::api::control::{HeldRecordReason, SyncControl, SyncPhase};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::{RecordKey, ScopeName};
use tablepro_sync::api::key_flows::LockCause;
use tablepro_sync::api::state::{Opened, Row, RowKey, RowRange, StateFiles, SyncTrust, Table};
use tablepro_sync::api::transport::{DeletedReason, TransportError};
use tablepro_sync_testing::service::{Policies, ScopeOwner};
use tablepro_sync_testing::{FakeDeviceStore, FakeServer, MemoryStateFiles};

use super::harness::{
    ACCOUNT, Crashing, Device, DeviceBuilder, MemoryAdapter, StoreFile, account, connection, id, identity,
    open_on_disk, personal, write,
};

fn stored(server: &FakeServer, record: &str) -> Option<Value> {
    server
        .stored(personal(), "connection", record)
        .and_then(|record| record.fields)
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

fn named(name: &str, icon: &str) -> Value {
    json!({"name": name, "icon_name": icon, "sort_order": 1})
}

#[tokio::test]
async fn two_devices_converge_on_creates_edits_and_deletes() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;

    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    mini.sync().await;
    let created = mini.connections.get(&id(1));
    mini.connections.put(&id(1), named("Prod 2", "db.example.com"));
    mini.sync().await;
    mac.sync().await;
    let edited = mac.connections.get(&id(1));
    mac.connections.remove(&id(1));
    mac.sync().await;
    mini.sync().await;

    assert_eq!(created, Some(connection("Prod")));
    assert_eq!(edited, Some(named("Prod 2", "db.example.com")));
    assert_eq!(mini.connections.get(&id(1)), None);
    let tombstone = server.stored(personal(), "connection", &id(1)).unwrap();
    assert_eq!(tombstone.deleted, Some(DeletedReason::User));
}

#[tokio::test]
async fn edits_to_different_fields_merge_and_the_same_field_takes_the_pusher() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections.put(&id(1), named("Prod", "a.example.com"));
    mac.sync().await;
    mini.sync().await;

    mac.connections.put(&id(1), named("Prod mac", "a.example.com"));
    mini.connections.put(&id(1), named("Prod", "b.example.com"));
    mac.sync().await;
    mini.sync().await;
    mac.sync().await;
    let merged = (mac.connections.get(&id(1)), mini.connections.get(&id(1)));
    mac.connections.put(&id(1), named("From mac", "b.example.com"));
    mini.connections.put(&id(1), named("From mini", "b.example.com"));
    mac.sync().await;
    mini.sync().await;
    mac.sync().await;

    let both = named("Prod mac", "b.example.com");
    assert_eq!(merged, (Some(both.clone()), Some(both)));
    assert_eq!(stored(&server, &id(1)), Some(named("From mini", "b.example.com")));
    assert_eq!(mac.connections.get(&id(1)), Some(named("From mini", "b.example.com")));
}

#[tokio::test]
async fn a_content_edit_revives_a_deletion_and_a_placement_edit_does_not() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections.put(&id(1), named("Edited", "a"));
    mac.connections.put(&id(2), named("Moved", "a"));
    mac.sync().await;
    mini.sync().await;

    mac.connections.remove(&id(1));
    mac.connections.remove(&id(2));
    mac.sync().await;
    mini.connections.put(&id(1), named("Edited", "changed"));
    mini.connections
        .put(&id(2), json!({"name": "Moved", "icon_name": "a", "sort_order": 9}));
    mini.sync().await;
    mac.sync().await;

    assert_eq!(stored(&server, &id(1)), Some(named("Edited", "changed")));
    assert_eq!(mac.connections.get(&id(1)), Some(named("Edited", "changed")));
    assert_eq!(
        server.stored(personal(), "connection", &id(2)).unwrap().deleted,
        Some(DeletedReason::User)
    );
    assert_eq!(mini.connections.get(&id(2)), None);
}

#[tokio::test]
async fn a_crash_between_the_store_write_and_the_commit_replays_with_no_effect() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let state = Crashing::new(MemoryStateFiles::new().open(identity("dev_mini")).await.unwrap());
    let armed = Arc::clone(&state.armed);
    let mini = DeviceBuilder::new(&server, "dev_mini").state(state).build().await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    mini.sync().await;

    mac.connections.put(&id(1), named("Prod 2", "db.example.com"));
    mac.sync().await;
    mini.connections.on_apply(move || armed.store(true, Ordering::SeqCst));
    let crashed = mini.pass().await;
    mini.connections.on_apply(|| {});
    let base_after_crash = mini
        .row(RowKey::Base(RecordKey::new(
            ScopeName::Personal,
            Kind::Connection,
            id(1),
        )))
        .await;
    let replay = mini.sync().await;

    assert!(matches!(crashed, Err(SyncError::State(_))));
    assert!(matches!(base_after_crash, Some(Row::Base(base)) if base.version == Some(1)));
    assert_eq!(mini.connections.get(&id(1)), Some(named("Prod 2", "db.example.com")));
    assert_eq!(mini.connections.applies(), 2, "the replay wrote the store again");
    assert_eq!(replay.pushed, 0);
    assert_eq!(server.stored(personal(), "connection", &id(1)).unwrap().version, 2);
}

#[tokio::test]
async fn a_lost_answer_is_settled_by_the_next_pull() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;

    mac.connections.put(&id(1), connection("Prod"));
    mac.wire.lose_next_answer();
    let lost = mac.pass().await;
    let next = mac.sync().await;

    assert!(matches!(
        lost,
        Err(SyncError::Transport(TransportError::Network { .. }))
    ));
    assert_eq!(next.pushed, 0);
    assert_eq!(server.stored(personal(), "connection", &id(1)).unwrap().version, 1);
    assert!(mac.rows(RowRange::Table(Table::Outbox)).await.is_empty());
}

#[tokio::test]
async fn a_batch_sent_again_keeps_its_key_until_the_server_forgets_it() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    mac.connections.put(&id(1), connection("Prod"));

    mac.wire.drop_next_push();
    assert!(mac.pass().await.is_err());
    mac.wire.drop_next_push();
    assert!(mac.pass().await.is_err());
    mac.clock.advance(86_400 * 1_000);
    mac.sync().await;

    let keys = mac.wire.keys();
    assert_eq!(keys.len(), 3);
    assert_eq!(keys[0], keys[1]);
    assert_ne!(keys[1], keys[2]);
    assert_eq!(stored(&server, &id(1)), Some(connection("Prod")));
}

#[tokio::test]
async fn the_queue_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let device_store = Arc::new(FakeDeviceStore::new());
    let server = FakeServer::new();
    let file = StoreFile::new();
    let connections = MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file));
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .state(open_on_disk(dir.path(), "dev_mac", &device_store).await)
        .connections(Arc::clone(&connections), Arc::clone(&file))
        .build()
        .await;
    mac.sync().await;
    connections.put(&id(1), connection("Offline edit"));
    mac.wire.drop_next_push();
    assert!(mac.pass().await.is_err());
    let sent = mac.wire.keys();
    let seed = Arc::clone(&mac.seed);
    drop(mac);

    let restarted = DeviceBuilder::new(&server, "dev_mac")
        .state(open_on_disk(dir.path(), "dev_mac", &device_store).await)
        .connections(Arc::clone(&connections), file)
        .seed(seed)
        .build()
        .await;
    let report = restarted.sync().await;

    assert_eq!(report.pushed, 1);
    assert_eq!(restarted.wire.keys(), sent);
    assert_eq!(stored(&server, &id(1)), Some(connection("Offline edit")));
}

#[tokio::test]
async fn a_refused_change_stays_on_the_device_and_is_not_sent_again() {
    let server = FakeServer::new();
    let envelopes = MemoryAdapter::new(Kind::SecretEnvelope, "secrets", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::Personal, Arc::clone(&envelopes))
        .build()
        .await;
    mac.sync().await;
    // No personal key version is on the server yet, so an envelope under one is `key_version_unknown`.
    let envelope = format!("connection/{}/password", id(1));
    envelopes.put(&envelope, json!({"suite": "tp1", "kv": 1, "nonce": "n", "ct": "c"}));
    mac.connections
        .put(&id(2), json!({"name": "Secret", "password": "hunter2"}));

    let first = mac.sync().await;
    let second = mac.sync().await;
    let held = mac.sync.held_records().await.unwrap();

    assert_eq!(first.refused.len(), 2);
    assert_eq!(mac.wire.pushed().len(), 1, "the refused envelope went up once");
    assert!(second.refused.iter().all(|(key, _)| key.record_id == id(2)));
    let codes: Vec<String> = held
        .iter()
        .filter_map(|record| match &record.reason {
            HeldRecordReason::Refused { code } => Some(code.clone()),
            HeldRecordReason::Held(_) => None,
        })
        .collect();
    assert!(codes.contains(&"key_version_unknown".to_owned()));
    assert!(codes.contains(&"secret_key".to_owned()));
    assert_eq!(stored(&server, &id(2)), None);
}

#[tokio::test]
async fn a_refused_change_is_not_sent_again_after_a_restart_until_it_changes() {
    let dir = tempfile::tempdir().unwrap();
    let device_store = Arc::new(FakeDeviceStore::new());
    let server = FakeServer::new();
    let envelopes = MemoryAdapter::new(Kind::SecretEnvelope, "secrets", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .state(open_on_disk(dir.path(), "dev_mac", &device_store).await)
        .adapter(ScopeName::Personal, Arc::clone(&envelopes))
        .build()
        .await;
    mac.sync().await;
    // No personal key version is on the server yet, so an envelope under one is `key_version_unknown`.
    let envelope = format!("connection/{}/password", id(1));
    envelopes.put(&envelope, json!({"suite": "tp1", "kv": 1, "nonce": "n", "ct": "c"}));
    let refused = mac.sync().await;
    let seed = Arc::clone(&mac.seed);
    drop(mac);

    let restarted = DeviceBuilder::new(&server, "dev_mac")
        .state(open_on_disk(dir.path(), "dev_mac", &device_store).await)
        .adapter(ScopeName::Personal, Arc::clone(&envelopes))
        .seed(Arc::clone(&seed))
        .build()
        .await;
    let held = restarted.sync.held_records().await.unwrap();
    let again = restarted.sync().await;
    let sent_again = restarted.wire.pushed().len();
    envelopes.put(&envelope, json!({"suite": "tp1", "kv": 1, "nonce": "m", "ct": "d"}));
    let changed = restarted.sync().await;

    assert_eq!(refused.refused.len(), 1);
    assert_eq!(
        held.iter().map(|record| &record.reason).collect::<Vec<_>>(),
        [&HeldRecordReason::Refused {
            code: "key_version_unknown".to_owned()
        }]
    );
    assert_eq!(sent_again, 0, "the same change is not sent again");
    assert!(again.refused.is_empty());
    assert_eq!(restarted.wire.pushed().len(), 1, "a change that differs goes up");
    assert_eq!(changed.refused.len(), 1);
}

#[tokio::test]
async fn a_local_only_connection_never_leaves_the_device() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;

    mac.connections.put_local_only(&id(1), connection("Local"));
    mac.connections.put(&id(2), connection("Synced"));
    mac.sync().await;

    assert_eq!(stored(&server, &id(1)), None);
    assert_eq!(stored(&server, &id(2)), Some(connection("Synced")));
}

#[tokio::test]
async fn a_kind_a_policy_turns_off_keeps_its_copies_and_goes_up_when_it_is_back_on() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;

    server.set_policies(Policies {
        personal_sync: false,
        ..Policies::default()
    });
    mac.sync().await;
    let kept = mac.connections.get(&id(1));
    mac.connections.put(&id(1), connection("Edited while off"));
    let off = mac.sync().await;
    server.set_policies(Policies::default());
    mac.sync().await;

    assert_eq!(kept, Some(connection("Prod")));
    assert_eq!(off.pushed, 0);
    let revived = server.stored(personal(), "connection", &id(1)).unwrap();
    assert_eq!(revived.deleted, None);
    assert_eq!(revived.fields, Some(connection("Edited while off")));
}

#[tokio::test]
async fn past_grace_the_pass_only_pulls() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    server.set_lapsed(true);
    mac.connections.put(&id(1), connection("Prod"));

    let report = mac.sync().await;

    assert!(report.pull_only);
    assert_eq!(mac.sync.status().phase, SyncPhase::PullOnly);
    assert_eq!(stored(&server, &id(1)), None);
}

// A store edited between passes has its row moved on by the next pass, though that pass writes nothing to it, so a
// later rollback to before the edit still shows as one.
#[tokio::test]
async fn a_pass_keeps_the_sequence_a_store_moved_on_to_without_it() {
    let server = FakeServer::new();
    let file = StoreFile::new();
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .connections(
            MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file)),
            Arc::clone(&file),
        )
        .build()
        .await;
    mini.sync().await;
    mini.connections.put(&id(1), connection("Edited"));
    let edited = file.stamp();

    mini.sync().await;

    assert_eq!(
        mini.row(RowKey::Store("connections".to_owned())).await,
        Some(Row::Store(tablepro_sync::api::state::StoreRow {
            store: "connections".to_owned(),
            generation: edited.generation,
            sequence: edited.sequence,
        }))
    );
}

#[tokio::test]
async fn a_restored_store_refills_every_kind_it_holds() {
    let server = FakeServer::new();
    let history = StoreFile::new();
    let queries = |file: &Arc<StoreFile>| MemoryAdapter::new(Kind::SavedQuery, "history.db", Arc::clone(file));
    let folders = |file: &Arc<StoreFile>| MemoryAdapter::new(Kind::SavedQueryFolder, "history.db", Arc::clone(file));
    let mac_file = StoreFile::new();
    let (mac_queries, mac_folders) = (queries(&mac_file), folders(&mac_file));
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::Personal, Arc::clone(&mac_queries))
        .adapter(ScopeName::Personal, Arc::clone(&mac_folders))
        .build()
        .await;
    let (mini_queries, mini_folders) = (queries(&history), folders(&history));
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .adapter(ScopeName::Personal, Arc::clone(&mini_queries))
        .adapter(ScopeName::Personal, Arc::clone(&mini_folders))
        .build()
        .await;
    mac_queries.put(&id(1), json!({"name": "Q", "query": "select 1"}));
    mac_folders.put(&id(2), json!({"name": "F"}));
    mac.sync().await;
    mini.sync().await;
    mac_queries.put(&id(1), json!({"name": "Q", "query": "select 2"}));
    mac_folders.put(&id(2), json!({"name": "F2"}));
    mac.sync().await;

    // The backup holds an older copy, which would read as edits, and a query the provider never saw.
    mini_queries.put(&id(1), json!({"name": "Q", "query": "select 0"}));
    mini_folders.put(&id(2), json!({"name": "F0"}));
    mini_queries.put(&id(3), json!({"name": "New", "query": "select 3"}));
    history.restored();
    mini.sync().await;

    assert_eq!(
        mini_queries.get(&id(1)),
        Some(json!({"name": "Q", "query": "select 2"}))
    );
    assert_eq!(mini_folders.get(&id(2)), Some(json!({"name": "F2"})));
    let query = |record: &str| {
        server
            .stored(personal(), "saved_query", record)
            .and_then(|record| record.fields)
    };
    assert_eq!(query(&id(1)), Some(json!({"name": "Q", "query": "select 2"})));
    assert_eq!(query(&id(3)), Some(json!({"name": "New", "query": "select 3"})));
}

#[tokio::test]
async fn a_stale_state_file_refills_and_the_pull_wins() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let files = MemoryStateFiles::new();
    let file = StoreFile::new();
    let connections = MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file));
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .state(files.open(identity("dev_mini")).await.unwrap())
        .connections(Arc::clone(&connections), Arc::clone(&file))
        .build()
        .await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    mini.sync().await;
    mac.connections.put(&id(1), connection("Newer"));
    mac.sync().await;
    connections.put(&id(1), connection("Restored with the file"));
    let seed = Arc::clone(&mini.seed);
    drop(mini);

    files.set_opened(
        identity("dev_mini"),
        Opened {
            sync_tables: SyncTrust::Refill,
            ..Opened::FRESH
        },
    );
    let reopened = DeviceBuilder::new(&server, "dev_mini")
        .state(files.open(identity("dev_mini")).await.unwrap())
        .connections(Arc::clone(&connections), file)
        .seed(seed)
        .build()
        .await;
    reopened.sync().await;

    assert_eq!(connections.get(&id(1)), Some(connection("Newer")));
    assert_eq!(stored(&server, &id(1)), Some(connection("Newer")));
}

#[tokio::test]
async fn a_removed_device_locks_and_syncs_nothing_personal() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    server.remove_row(&tablepro_sync::api::ids::DeviceRowId("dev_mac".to_owned()));

    let removed = mac.pass().await;

    assert_eq!(removed.err(), Some(SyncError::Transport(TransportError::DeviceRemoved)));
    assert_eq!(mac.hooks.locked(), Some(LockCause::DeviceRemoved));
}

#[tokio::test]
async fn a_history_prune_pushes_nothing_and_a_deletion_goes_up_from_its_tombstone() {
    let server = FakeServer::new();
    let entries = MemoryAdapter::new(Kind::HistoryEntry, "history.db", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::History, Arc::clone(&entries))
        .build()
        .await;
    history_key(&mac).await;
    let entry = id;
    entries.put(&entry(1), json!({"suite": "tp1", "kv": 1, "ct": "one"}));
    entries.put(&entry(2), json!({"suite": "tp1", "kv": 1, "ct": "two"}));
    mac.sync().await;

    entries.remove(&entry(1));
    let pruned = mac.sync().await;
    entries.delete_entry(&entry(2));
    let deleted = mac.sync().await;

    let history = |n: u8| server.stored(ScopeOwner::History(account()), "history_entry", &entry(n));
    assert_eq!(pruned.pushed, 0);
    assert_eq!(history(1).unwrap().deleted, None);
    assert_eq!(deleted.pushed, 1);
    assert_eq!(history(2).unwrap().deleted, Some(DeletedReason::User));
    assert!(entries.tombstones().is_empty());
    assert!(
        mac.row(RowKey::Base(RecordKey::new(
            ScopeName::History,
            Kind::HistoryEntry,
            entry(1)
        )))
        .await
        .is_none()
    );
}

#[tokio::test]
async fn a_pull_of_a_kind_with_no_adapter_is_held_by_id() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    mac.push_raw(
        ScopeName::Personal,
        vec![super::harness::write("future_kind", "x1", None, json!({"a": 1}))],
    )
    .await;

    mac.sync().await;

    let held = mac.rows(RowRange::Table(Table::Held)).await;
    assert!(matches!(&held[..], [Row::Held(row)] if row.key.record_id == "x1"));
    assert_eq!(mac.sync.status().held, 1);
}

#[tokio::test]
async fn before_approval_a_device_pulls_key_objects_only_and_its_first_approved_pass_lets_the_pull_win() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    let mini = DeviceBuilder::new(&server, "dev_mini").unapproved().build().await;
    mini.connections.put(&id(1), connection("An older copy"));
    mini.connections.put(&id(2), connection("Not yet"));

    let before = mini.sync().await;
    let pulled_before = mini.connections.get(&id(1));
    server.approve(
        &tablepro_sync::api::ids::DeviceRowId("dev_mini".to_owned()),
        mini.seed.public().unwrap().0,
    );
    mini.sync().await;

    assert_eq!(pulled_before, Some(connection("An older copy")));
    assert_eq!(before.pushed, 0);
    assert_eq!(mini.connections.get(&id(1)), Some(connection("Prod")));
    assert_eq!(stored(&server, &id(1)), Some(connection("Prod")));
    assert_eq!(stored(&server, &id(2)), Some(connection("Not yet")));
}

#[tokio::test]
async fn an_idle_pass_commits_nothing() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    mac.sync().await;
    let counter = || async {
        match mac.row(RowKey::Binding).await {
            Some(Row::Binding(binding)) => binding.counter,
            _ => panic!("no binding row"),
        }
    };
    let before = counter().await;

    mac.sync().await;

    assert_eq!(counter().await, before);
}

#[tokio::test]
async fn a_journal_pass_sends_only_what_the_journal_named() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    mac.sync().await;
    mac.connections.put(&id(1), connection("Named"));
    mac.connections.put(&id(2), connection("Not named"));

    mac.sync.journal().changed(&[tablepro_sync::engine::JournalEntry {
        kind: Kind::Connection,
        written: vec![id(1)],
        deleted: Vec::new(),
    }]);
    let journal = mac
        .sync
        .run_pass(tablepro_sync::api::control::PassReason::Journal)
        .await
        .unwrap();
    let named = (stored(&server, &id(1)), stored(&server, &id(2)));
    let poll = mac.sync().await;

    assert_eq!(journal.pushed, 1);
    assert_eq!(named, (Some(connection("Named")), None));
    assert_eq!(poll.pushed, 1);
    assert_eq!(stored(&server, &id(2)), Some(connection("Not named")));
}

#[tokio::test]
async fn a_history_entry_deleted_on_two_devices_lets_its_tombstone_go() {
    let server = FakeServer::new();
    let mac_entries = MemoryAdapter::new(Kind::HistoryEntry, "history.db", StoreFile::new());
    let mini_entries = MemoryAdapter::new(Kind::HistoryEntry, "history.db", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::History, Arc::clone(&mac_entries))
        .build()
        .await;
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .adapter(ScopeName::History, Arc::clone(&mini_entries))
        .build()
        .await;
    history_key(&mac).await;
    mac_entries.put(&id(1), json!({"suite": "tp1", "kv": 1, "ct": "one"}));
    mac.sync().await;
    mini.sync().await;
    mini.sync().await;

    mac_entries.delete_entry(&id(1));
    mac.sync().await;
    mini_entries.delete_entry(&id(1));
    mini.sync().await;

    assert!(mini_entries.tombstones().is_empty());
    assert_eq!(
        server
            .stored(ScopeOwner::History(account()), "history_entry", &id(1))
            .unwrap()
            .deleted,
        Some(DeletedReason::User)
    );
}

#[tokio::test]
async fn a_refill_cut_short_after_its_snapshot_keeps_the_edits_made_since() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let file = StoreFile::new();
    let connections = MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file));
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .connections(Arc::clone(&connections), Arc::clone(&file))
        .build()
        .await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    mini.sync().await;

    file.restored();
    connections.put(&id(2), connection("Only in the backup"));
    mini.wire.drop_next_push();
    assert!(mini.pass().await.is_err());
    connections.put(&id(1), connection("Edited after the refill"));
    mini.sync().await;

    assert_eq!(stored(&server, &id(1)), Some(connection("Edited after the refill")));
    assert_eq!(stored(&server, &id(2)), Some(connection("Only in the backup")));
}
