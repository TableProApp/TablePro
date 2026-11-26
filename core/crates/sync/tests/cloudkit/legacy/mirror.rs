// What every pass and every journal signal leave the previous stable (0054, Downgrade mirror; 0060).

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_records::record_id::{favourite_table, uuid_id};
use tablepro_sync::api::RecordAdapter;
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::legacy::LegacyMirror;
use tablepro_sync::api::state::{Standing, StateFiles};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{Clock, Journal, JournalEntry, StopSignal};
use tablepro_sync_testing::FakeLegacyMirror;
use uuid::Uuid;

use super::{dirty, marked, record, signed_in, tombstone, tombstones, transport};
use crate::support::{A, B, C, KINDS, Rig, USER, name, projected};

const RETRY: i64 = 15;

fn group(name: &str) -> serde_json::Value {
    json!({"name": name})
}

fn mirror() -> Arc<FakeLegacyMirror> {
    Arc::new(FakeLegacyMirror::holding(signed_in()))
}

fn entry(kind: Kind, written: &[&str], deleted: &[&str]) -> JournalEntry {
    JournalEntry {
        kind,
        written: written.iter().map(|id| (*id).to_owned()).collect(),
        deleted: deleted.iter().map(|id| (*id).to_owned()).collect(),
    }
}

fn pair(record_type: &str, id: &str) -> (String, String) {
    (record_type.to_owned(), id.to_owned())
}

#[tokio::test]
async fn after_a_pass_the_mirror_holds_the_token_the_bases_and_the_account() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Tag, B, &json!({"name": "prod"}));
    let mirror = mirror();

    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();
    let held = mirror.metadata();

    assert_eq!(held.token, rig.token().await);
    assert_eq!(held.account.as_deref(), Some(USER));
    assert_eq!(held.zone_state.as_deref(), Some("confirmed"));
    assert!(held.dirty.is_empty() && held.tombstones.is_empty());
    let cached: Vec<(&str, Option<Vec<u8>>)> = held
        .cache
        .iter()
        .map(|cached| (cached.name.as_str(), cached.system_fields.clone()))
        .collect();
    let zone = |kind, id| rig.cloud.record(USER, &name(kind, id)).unwrap().system_fields;
    assert_eq!(
        cached,
        [
            (name(Kind::Group, A).as_str(), zone(Kind::Group, A)),
            (name(Kind::Tag, B).as_str(), zone(Kind::Tag, B))
        ]
    );
    assert!(
        held.cache
            .iter()
            .all(|cached| cached.fields.iter().all(|field| field.name != "modifiedAtLocal"))
    );
    for read in [
        "Connection",
        "ConnectionGroup",
        "ConnectionTag",
        "AppSettings",
        "FavoriteTable",
    ] {
        assert!(held.readable_record_types.iter().any(|held| held == read), "{read}");
    }
    assert!(
        !held
            .readable_record_types
            .iter()
            .any(|held| held == "SQLFavoriteFolder")
    );
}

#[tokio::test]
async fn an_edit_left_unsent_stays_dirty_and_a_sent_one_does_not() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &group("Home 2")));
    rig.cloud.fail_record(&name(Kind::Group, A), RETRY);

    let report = sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(report.push.saved, 1);
    assert_eq!(dirty(&mirror.metadata()), [pair("ConnectionGroup", A)]);
}

#[tokio::test]
async fn a_deletion_left_unsent_is_a_tombstone_naming_the_connection_it_belonged_to() {
    let rig = Rig::new().await;
    let connection = Uuid::from_u128(11);
    let id = favourite_table(connection, Some("db"), Some("public"), "users").id;
    rig.save_elsewhere(
        Kind::FavouriteTable,
        &id,
        &json!({"connection_id": uuid_id(connection), "database": "db", "schema": "public", "name": "users"}),
    );
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::FavouriteTable).remove(&id);
    rig.cloud.fail_record(&name(Kind::FavouriteTable, &id), RETRY);

    sync.run_pass(PassReason::Poll).await.unwrap();
    let held = mirror.metadata();

    assert_eq!(tombstones(&held), [pair("FavoriteTable", &id)]);
    assert_eq!(held.tombstones[0].owner, Some(connection));
}

#[tokio::test]
async fn an_edit_and_a_deletion_made_offline_are_marked_before_any_pass() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let before = mirror.marks();

    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    rig.store(Kind::Group).remove(B);
    sync.journal().changed(&[entry(Kind::Group, &[A], &[B])]);
    sync.journal().changed(&[entry(Kind::HistoryEntry, &[C], &[])]);
    marked(&mirror, before + 1).await;
    let held = mirror.metadata();

    assert_eq!(dirty(&held), [pair("ConnectionGroup", A)]);
    assert_eq!(tombstones(&held), [pair("ConnectionGroup", B)]);
    assert!(held.tombstones[0].deleted_at_ms >= 1_767_225_600_000);
}

#[tokio::test]
async fn a_pass_that_changed_nothing_writes_nothing() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);

    sync.run_pass(PassReason::Launch).await.unwrap();
    sync.run_pass(PassReason::Poll).await.unwrap();
    let after_two = mirror.writes();
    rig.save_elsewhere(Kind::Group, A, &group("Work 2"));
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(after_two, 1);
    assert_eq!(mirror.writes(), 2);
}

#[tokio::test]
async fn a_value_waiting_for_the_person_is_held_by_id_and_a_record_held_whole_leaves_its_type_unread() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.internal"}));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.approve_everything().await;
    sync.run_pass(PassReason::Poll).await.unwrap();
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "host": "elsewhere.example.com"}),
    );

    sync.run_pass(PassReason::Poll).await.unwrap();
    let waiting = mirror.metadata();
    rig.save_elsewhere(Kind::Connection, B, &json!({"name": "new", "host": "db.example.com"}));
    sync.run_pass(PassReason::Poll).await.unwrap();
    let whole = mirror.metadata();

    assert_eq!(waiting.changes_held_for_unreadable, [name(Kind::Connection, A)]);
    assert!(waiting.dirty.is_empty());
    assert!(waiting.readable_record_types.iter().any(|read| read == "Connection"));
    assert!(!whole.readable_record_types.iter().any(|read| read == "Connection"));
    assert!(whole.readable_record_types.iter().any(|read| read == "ConnectionGroup"));
}

#[tokio::test]
async fn a_type_with_no_adapter_keeps_the_swift_engine_s_marks_and_is_read_whole_by_the_previous_stable() {
    let rig = Rig::new().await;
    let mut left = signed_in();
    left.dirty.push(record("ConnectionTag", A));
    left.tombstones.push(tombstone("ConnectionTag", B));
    left.changes_held_for_unreadable.push(name(Kind::Tag, C));
    left.readable_record_types.push("ConnectionTag/color.v1".to_owned());
    left.standing.push(tablepro_sync::api::legacy::LegacyStanding {
        connection: Uuid::from_u128(3),
        standing: Standing::LocalOnly,
    });
    let mirror = Arc::new(FakeLegacyMirror::holding(left));
    let adapters: Vec<Arc<dyn RecordAdapter>> = rig
        .adapters()
        .into_iter()
        .filter(|adapter| !matches!(adapter.kind(), Kind::Tag | Kind::Connection))
        .collect();
    let sync = CloudKitSync::new(CloudKitParts {
        transport: transport(&rig),
        files: Arc::clone(&rig.files) as Arc<dyn StateFiles>,
        adapters,
        categories: Categories::new(KINDS),
        clock: Arc::clone(&rig.clock) as Arc<dyn Clock>,
        stop: StopSignal::new(),
        journal: Journal::default(),
        events: None,
        last_account: None,
    })
    .with_legacy_mirror(Arc::clone(&mirror) as Arc<dyn LegacyMirror>);

    sync.run_pass(PassReason::Launch).await.unwrap();
    let held = mirror.metadata();

    assert_eq!(dirty(&held), [pair("ConnectionTag", A)]);
    assert_eq!(tombstones(&held), [pair("ConnectionTag", B)]);
    assert_eq!(held.changes_held_for_unreadable, [name(Kind::Tag, C)]);
    assert_eq!(held.standing.len(), 1);
    assert!(
        !held
            .readable_record_types
            .iter()
            .any(|read| read.starts_with("ConnectionTag"))
    );
    assert!(!held.readable_record_types.iter().any(|read| read == "Connection"));
    assert!(held.readable_record_types.iter().any(|read| read == "ConnectionGroup"));
}

// A journal pass diffs only what it was told of (0060): a write the journal missed waits for the next full pass.
#[tokio::test]
async fn a_journal_pass_marks_only_the_records_it_was_told_of() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &group("Home 2")));
    rig.cloud.fail_record(&name(Kind::Group, A), RETRY);
    rig.cloud.fail_record(&name(Kind::Group, B), RETRY);

    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    sync.run_pass(PassReason::Journal).await.unwrap();
    let journal_pass = dirty(&mirror.metadata());
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(journal_pass, [pair("ConnectionGroup", A)]);
    assert_eq!(dirty(&mirror.metadata()), [pair("ConnectionGroup", B)]);
}

#[tokio::test]
async fn another_icloud_account_s_pass_writes_that_account_s_metadata() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.cloud.switch_account(Some("_9a8b7c"));

    sync.run_pass(PassReason::AccountChanged).await.unwrap();
    let held = mirror.metadata();

    assert_eq!(held.account.as_deref(), Some("_9a8b7c"));
    assert!(held.cache.iter().all(|cached| {
        rig.cloud
            .record(USER, &cached.name)
            .and_then(|record| record.system_fields)
            != cached.system_fields
    }));
}

#[tokio::test]
async fn an_edit_reverted_before_the_next_pass_leaves_no_mark() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let base = rig.store(Kind::Group).fields(A).unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    rig.store(Kind::Group).put(A, base);
    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    sync.flush_legacy_marks().await.unwrap();
    let marked_dirty = dirty(&mirror.metadata());

    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(marked_dirty, [pair("ConnectionGroup", A)]);
    assert!(mirror.metadata().dirty.is_empty());
}

#[tokio::test]
async fn a_flush_returns_once_every_signal_so_far_marked_the_host() {
    let rig = Rig::new().await;
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();

    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    sync.journal().changed(&[entry(Kind::Tag, &[B], &[])]);
    sync.flush_legacy_marks().await.unwrap();

    assert_eq!(
        dirty(&mirror.metadata()),
        [pair("ConnectionGroup", A), pair("ConnectionTag", B)]
    );
}

#[tokio::test]
async fn a_signal_queued_as_the_engine_stops_still_reaches_the_host() {
    let rig = Rig::new().await;
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let before = mirror.marks();

    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    drop(sync);
    marked(&mirror, before + 1).await;

    assert_eq!(dirty(&mirror.metadata()), [pair("ConnectionGroup", A)]);
}

#[tokio::test]
async fn an_owned_record_deleted_offline_is_marked_with_its_connection() {
    let rig = Rig::new().await;
    let connection = Uuid::from_u128(12);
    let id = favourite_table(connection, Some("db"), Some("public"), "orders").id;
    rig.save_elsewhere(
        Kind::FavouriteTable,
        &id,
        &json!({"connection_id": uuid_id(connection), "database": "db", "schema": "public", "name": "orders"}),
    );
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();

    rig.store(Kind::FavouriteTable).remove(&id);
    sync.journal().changed(&[entry(Kind::FavouriteTable, &[], &[&id])]);
    sync.flush_legacy_marks().await.unwrap();
    let held = mirror.metadata();

    assert_eq!(tombstones(&held), [pair("FavoriteTable", &id)]);
    assert_eq!(held.tombstones[0].owner, Some(connection));
}

// After a restart, offline: the deletion of an owned record made before the launch's first pass reaches CloudKit still
// names its connection, read from the state file's bases before any CloudKit call.
#[tokio::test]
async fn an_owned_record_deleted_before_the_first_pass_reaches_icloud_is_marked_with_its_connection() {
    let rig = Rig::new().await;
    let connection = Uuid::from_u128(12);
    let id = favourite_table(connection, Some("db"), Some("public"), "orders").id;
    rig.save_elsewhere(
        Kind::FavouriteTable,
        &id,
        &json!({"connection_id": uuid_id(connection), "database": "db", "schema": "public", "name": "orders"}),
    );
    let mirror = mirror();
    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();
    let restarted = rig
        .sync(Some(USER))
        .with_legacy_mirror(Arc::clone(&mirror) as Arc<dyn LegacyMirror>);
    rig.cloud
        .fail_next(tablepro_sync::api::cloudkit::CloudKitFailure::Network);

    rig.store(Kind::FavouriteTable).remove(&id);
    restarted.journal().changed(&[entry(Kind::FavouriteTable, &[], &[&id])]);
    let offline = restarted.run_pass(PassReason::Launch).await;
    restarted.flush_legacy_marks().await.unwrap();
    let held = mirror.metadata();

    assert!(offline.is_err());
    assert_eq!(tombstones(&held), [pair("FavoriteTable", &id)]);
    assert_eq!(held.tombstones[0].owner, Some(connection));
}

// With iCloud off the marks go on their own: a deletion of an owned record waits for the owners the last iCloud file
// names, so it is marked with its connection, not dropped.
#[tokio::test]
async fn with_icloud_off_an_owned_deletion_waits_for_its_owner_and_is_marked() {
    let rig = Rig::new().await;
    let connection = Uuid::from_u128(12);
    let id = favourite_table(connection, Some("db"), Some("public"), "orders").id;
    rig.save_elsewhere(
        Kind::FavouriteTable,
        &id,
        &json!({"connection_id": uuid_id(connection), "database": "db", "schema": "public", "name": "orders"}),
    );
    let mirror = mirror();
    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();
    let marks = tablepro_sync::cloudkit::LegacyMarks::new(
        Arc::clone(&mirror) as Arc<dyn LegacyMirror>,
        Arc::clone(&rig.clock) as Arc<dyn Clock>,
    );
    let state = rig.files.open(Rig::identity()).await.unwrap();

    marks.changed(&[entry(Kind::FavouriteTable, &[], &[&id])]);
    marks.owners_from(Some(state.as_ref())).await.unwrap();
    marks.flush().await.unwrap();
    let held = mirror.metadata();

    assert_eq!(tombstones(&held), [pair("FavoriteTable", &id)]);
    assert_eq!(held.tombstones[0].owner, Some(connection));
}

// A pulled host waits for the person while the device keeps its own: the previous stable gets the record as it was
// before that pull, change tag and fields, so a push it makes after a downgrade is refused and merges rather than
// sending the device's old host over the pulled one.
#[tokio::test]
async fn a_record_waiting_for_approval_goes_to_the_previous_stable_as_it_was_before_the_pull() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.internal"}));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.approve_everything().await;
    sync.run_pass(PassReason::Poll).await.unwrap();
    let before = rig.cloud.record(USER, &name(Kind::Connection, A)).unwrap();
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "host": "elsewhere.example.com"}),
    );

    sync.run_pass(PassReason::Poll).await.unwrap();
    let waiting = rig.waiting().await;
    let cached = mirror
        .metadata()
        .cache
        .into_iter()
        .find(|record| record.name == name(Kind::Connection, A))
        .unwrap();
    rig.approve_everything().await;
    sync.run_pass(PassReason::Poll).await.unwrap();
    let after = mirror
        .metadata()
        .cache
        .into_iter()
        .find(|record| record.name == name(Kind::Connection, A))
        .unwrap();

    assert_eq!(waiting.len(), 1);
    assert_eq!(cached.system_fields, before.system_fields);
    assert_eq!(
        cached
            .fields
            .iter()
            .find(|field| field.name == "host")
            .map(|field| &field.value),
        before
            .fields
            .iter()
            .find(|field| field.name == "host")
            .map(|field| &field.value)
    );
    assert_ne!(after.system_fields, before.system_fields);
}

// A deletion the pass sent is not marked again by a signal that was still queued when it sent it.
#[tokio::test]
async fn a_deletion_the_pass_sent_does_not_come_back_from_a_queued_mark() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();

    rig.store(Kind::Group).remove(A);
    sync.journal().changed(&[entry(Kind::Group, &[], &[A])]);
    sync.run_pass(PassReason::Journal).await.unwrap();
    sync.flush_legacy_marks().await.unwrap();

    assert!(rig.zone_fields(Kind::Group, A).is_none());
    assert!(mirror.metadata().tombstones.is_empty());
}

#[tokio::test]
async fn a_mark_the_host_refused_is_sent_again_and_a_flush_says_so_until_then() {
    let rig = Rig::new().await;
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    // The queue's own try, then the flush's.
    mirror.fail_marks(2);

    sync.journal().changed(&[entry(Kind::Group, &[A], &[])]);
    let refused = sync.flush_legacy_marks().await;
    let after_refusal = dirty(&mirror.metadata());
    let again = sync.flush_legacy_marks().await;

    assert!(refused.is_err());
    assert!(after_refusal.is_empty());
    assert!(again.is_ok());
    assert_eq!(dirty(&mirror.metadata()), [pair("ConnectionGroup", A)]);
}

#[tokio::test]
async fn an_owned_record_that_never_reached_the_zone_gets_no_tombstone_from_the_journal() {
    let rig = Rig::new().await;
    let mirror = mirror();
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let id = favourite_table(Uuid::from_u128(13), Some("db"), Some("public"), "local").id;

    sync.journal().changed(&[entry(Kind::FavouriteTable, &[], &[&id])]);
    sync.flush_legacy_marks().await.unwrap();

    assert!(mirror.metadata().tombstones.is_empty());
}
