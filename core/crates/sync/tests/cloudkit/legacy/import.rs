// The first launch takes over from the Swift engine (0054, First launch), and takes over again after an older build
// ran in between; its own writes and marks never read as one.

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitField, CloudKitTransport, CloudKitValue};
use tablepro_sync::api::control::{PassReason, SyncControl, SyncPhase};
use tablepro_sync::api::ids::ChangeTag;
use tablepro_sync::api::legacy::LegacyMirror;
use tablepro_sync::api::state::HeldReason;
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::engine::JournalEntry;
use tablepro_sync_testing::FakeLegacyMirror;
use uuid::Uuid;

use crate::faults::Flaky;

use super::{Counting, PreviousStable, marked, record, signed_in, synced, tombstone, tombstones};
use crate::support::{A, B, C, KINDS, Rig, USER, name, projected};

fn group(name: &str) -> serde_json::Value {
    json!({"name": name})
}

async fn zone_tag(rig: &Rig, kind: Kind, id: &str) -> Vec<u8> {
    rig.cloud.record(USER, &name(kind, id)).unwrap().system_fields.unwrap()
}

#[tokio::test]
async fn the_first_launch_resumes_at_the_swift_token_and_sends_only_what_the_swift_engine_left_unsent() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    rig.save_elsewhere(Kind::Tag, C, &json!({"name": "prod"}));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    left.dirty.push(record("ConnectionGroup", A));
    rig.store(Kind::Tag).remove(C);
    left.tombstones.push(tombstone("ConnectionTag", C));
    mirror.replace(left);
    rig.save_elsewhere(Kind::Group, B, &group("Home 2"));

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(!report.fetch.full);
    assert_eq!((report.push.queued, report.push.saved, report.push.deleted), (2, 1, 1));
    assert_eq!(report.push.merged, 0);
    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &group("Work 2")))
    );
    assert!(rig.zone_fields(Kind::Tag, C).is_none());
    assert_eq!(
        rig.store(Kind::Group).fields(B),
        Some(projected(Kind::Group, B, &group("Home 2")))
    );
}

#[tokio::test]
async fn another_account_s_metadata_leaves_its_position_and_cache_behind() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut other = mirror.metadata();
    other.account = Some("_9a8b7c".to_owned());
    mirror.replace(other);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(report.fetch.full);
    assert_eq!(report.push.saved, 0);
}

#[tokio::test]
async fn a_type_the_older_build_did_not_read_starts_a_full_fetch() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .pull()
    .await;
    let mut narrow = mirror.metadata();
    narrow.readable_record_types.retain(|read| read != "ConnectionTag");
    mirror.replace(narrow);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(report.fetch.full);
}

#[tokio::test]
async fn a_tombstone_with_no_cached_copy_deletes_by_name_and_one_kept_off_sync_stays() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = synced(&rig).await;
    let kept_off = Uuid::from_u128(77);
    let mut left = mirror.metadata();
    left.cache.retain(|cached| cached.name != name(Kind::Group, A));
    rig.store(Kind::Group).remove(A);
    rig.store(Kind::Group).remove(B);
    left.tombstones.push(tombstone("ConnectionGroup", A));
    let mut owned = tombstone("ConnectionGroup", B);
    owned.owner = Some(kept_off);
    left.tombstones.push(owned);
    left.owners_kept_off_sync.push(kept_off);
    mirror.replace(left);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(report.push.deleted, 1);
    assert!(rig.zone_fields(Kind::Group, A).is_none());
    assert!(rig.zone_fields(Kind::Group, B).is_some());
    assert_eq!(
        tombstones(&mirror.metadata()),
        [("ConnectionGroup".to_owned(), B.to_owned())]
    );
}

#[tokio::test]
async fn a_tombstone_with_no_cached_copy_stays_a_deletion_through_a_full_fetch() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.cache.clear();
    left.readable_record_types.retain(|read| read != "ConnectionGroup");
    rig.store(Kind::Group).remove(A);
    left.tombstones.push(tombstone("ConnectionGroup", A));
    mirror.replace(left);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(report.fetch.full);
    assert!(!rig.store(Kind::Group).holds(A));
    assert!(rig.zone_fields(Kind::Group, A).is_none());
}

#[tokio::test]
async fn a_first_launch_whose_swift_metadata_does_not_read_syncs_nothing_until_it_does() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    rig.store(Kind::Group).remove(A);
    left.tombstones.push(tombstone("ConnectionGroup", A));
    mirror.replace(left);
    mirror.fail_reads(1);
    let sync = rig.sync_mirrored(&mirror);

    let failed = sync.run_pass(PassReason::Launch).await;
    let untouched = (
        rig.store(Kind::Group).holds(A),
        rig.zone_fields(Kind::Group, A).is_some(),
    );
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(failed.unwrap_err().code(), "sync.adapter.host");
    assert_eq!(untouched, (false, true));
    assert!(!rig.store(Kind::Group).holds(A));
    assert!(rig.zone_fields(Kind::Group, A).is_none());
}

// An older build fetched a record and deleted it offline: an upgrade that synced before reading its metadata would
// take the record back as new from its own older token.
#[tokio::test]
async fn a_later_launch_whose_swift_metadata_does_not_read_syncs_nothing_until_it_does() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .pull()
    .await;
    rig.store(Kind::Group).remove(B);
    let mut deleted = mirror.metadata();
    deleted.tombstones.push(tombstone("ConnectionGroup", B));
    mirror.replace(deleted);
    mirror.fail_reads(1);
    let upgraded = rig.sync_mirrored(&mirror);

    let failed = upgraded.run_pass(PassReason::Launch).await;
    let restored = rig.store(Kind::Group).holds(B);
    upgraded.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(failed.unwrap_err().code(), "sync.adapter.host");
    assert!(!restored);
    assert!(!rig.store(Kind::Group).holds(B));
    assert!(rig.zone_fields(Kind::Group, B).is_none());
}

#[tokio::test]
async fn a_fetch_by_name_that_fails_fails_the_import_and_the_next_pass_runs_it_again() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.cache.clear();
    rig.store(Kind::Group).remove(A);
    left.tombstones.push(tombstone("ConnectionGroup", A));
    left.readable_record_types.retain(|read| read != "ConnectionGroup");
    mirror.replace(left);
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    flaky.wait_on_read(&name(Kind::Group, A), 1_000);
    let sync = rig
        .sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None)
        .with_legacy_mirror(Arc::clone(&mirror) as Arc<dyn LegacyMirror>);

    let failed = sync.run_pass(PassReason::Launch).await;
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert!(failed.is_err());
    assert!(!rig.store(Kind::Group).holds(A));
    assert!(rig.zone_fields(Kind::Group, A).is_none());
}

#[tokio::test]
async fn an_import_that_finds_the_zone_removed_leaves_upload_again_to_the_person() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.cache.clear();
    left.tombstones.push(tombstone("ConnectionGroup", B));
    mirror.replace(left);
    rig.cloud.remove_zone_by_user(USER);
    let sync = rig.sync_mirrored(&mirror);

    let pass = sync.run_pass(PassReason::Launch).await;
    let phase = sync.status().phase;
    sync.upload_again().await.unwrap();

    assert_eq!(
        pass.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::ZoneDeletedByUser)
    );
    assert_eq!(phase, SyncPhase::ZoneRemoved);
    assert!(rig.zone_fields(Kind::Group, A).is_some());
}

#[tokio::test]
async fn a_zone_the_swift_engine_saw_removed_stays_removed_and_nothing_goes_up() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.zone_state = Some("removed".to_owned());
    mirror.replace(left);
    rig.cloud.remove_zone_by_user(USER);
    let sync = rig.sync_mirrored(&mirror);

    let pass = sync.run_pass(PassReason::Launch).await;

    assert_eq!(
        pass.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::ZoneDeletedByUser)
    );
    assert_eq!(sync.status().phase, SyncPhase::ZoneRemoved);
    assert!(rig.cloud.record_names(USER).is_empty());
}

// The Swift engine saw the zone removed, and another device made it again before this build's first pass: nothing
// goes up until this device's person asks to upload again, and the mirror says removed for the previous stable.
#[tokio::test]
async fn a_zone_the_swift_engine_saw_removed_waits_for_upload_again_once_made_again() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.zone_state = Some("removed".to_owned());
    mirror.replace(left);
    rig.store(Kind::Group).put(B, projected(Kind::Group, B, &group("Only here")));
    let sync = rig.sync_mirrored(&mirror);

    let _ = sync.run_pass(PassReason::Launch).await;
    let _ = sync.run_pass(PassReason::Poll).await;

    assert!(rig.zone_fields(Kind::Group, B).is_none());
    assert_eq!(mirror.metadata().zone_state.as_deref(), Some("removed"));
}

#[tokio::test]
async fn a_change_held_for_a_copy_the_swift_engine_could_not_read_is_fetched_by_name() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    rig.save_elsewhere(Kind::Group, A, &group("Work 2"));
    let passed = rig
        .cloud
        .fetch_changes(USER.to_owned(), mirror.metadata().token)
        .await
        .unwrap()
        .token;
    let mut left = mirror.metadata();
    left.token = Some(passed);
    left.changes_held_for_unreadable = vec![name(Kind::Group, A)];
    mirror.replace(left);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(report.fetch.counts.recovered, 1);
    assert_eq!(
        rig.store(Kind::Group).fields(A),
        Some(projected(Kind::Group, A, &group("Work 2")))
    );
}

#[tokio::test]
async fn a_deletion_deferred_for_a_category_that_is_off_waits_for_it() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    rig.delete_elsewhere(Kind::Group, A);
    let passed = rig
        .cloud
        .fetch_changes(USER.to_owned(), mirror.metadata().token)
        .await
        .unwrap()
        .token;
    let mut left = mirror.metadata();
    left.token = Some(passed);
    left.deferred_deletions = vec![name(Kind::Group, A)];
    left.readable_record_types.retain(|read| read != "ConnectionGroup");
    mirror.replace(left);
    rig.turn_off(Kind::Group);
    let sync = rig.sync_mirrored(&mirror);

    sync.run_pass(PassReason::Launch).await.unwrap();
    let waited = rig.store(Kind::Group).holds(A) && rig.deferred(Kind::Group, A).await.is_some();
    sync.set_categories(Categories::new(KINDS));
    sync.run_pass(PassReason::Person).await.unwrap();

    assert!(waited);
    assert!(!rig.store(Kind::Group).holds(A));
}

#[tokio::test]
async fn a_state_file_that_held_the_zone_before_the_mirror_keeps_what_it_holds() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.sync(None).run_pass(PassReason::Launch).await.unwrap();
    let mut stale = signed_in();
    stale.token = Some(vec![9; 16]);
    let mirror = Arc::new(FakeLegacyMirror::holding(stale));

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(!report.fetch.full && !report.fetch.token_expired);
    assert_eq!(
        rig.base(Kind::Group, A).await.map(|base| base.tag),
        Some(ChangeTag::CloudKit(zone_tag(&rig, Kind::Group, A).await))
    );
    assert_eq!(mirror.writes(), 1);
}

#[tokio::test]
async fn an_older_build_that_pulled_and_pushed_in_between_is_imported_again() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();
    rig.save_elsewhere(Kind::Group, B, &group("Home 2"));
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    let mut edited = mirror.metadata();
    edited.dirty.push(record("ConnectionGroup", A));
    mirror.replace(edited);
    PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .pass()
    .await;
    let counting = Counting::new(&rig.cloud);
    let upgraded = rig
        .sync_through(Arc::clone(&counting) as Arc<dyn CloudKitTransport>, None)
        .with_legacy_mirror(Arc::clone(&mirror) as Arc<dyn LegacyMirror>);

    let report = upgraded.run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(counting.changed(), 0);
    assert_eq!(report.push.queued, 0);
    assert_eq!(report.fetch.counts.written, 0);
    assert_eq!(
        rig.base(Kind::Group, A).await.map(|base| base.tag),
        Some(ChangeTag::CloudKit(zone_tag(&rig, Kind::Group, A).await))
    );
    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &group("Work 2")))
    );
    assert_eq!(
        rig.store(Kind::Group).fields(B),
        Some(projected(Kind::Group, B, &group("Home 2")))
    );
}

#[tokio::test]
async fn its_own_write_and_marks_are_no_older_build_even_when_system_fields_read_back_anew() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let first = rig.sync_mirrored(&mirror);
    first.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    first.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: Vec::new(),
    }]);
    marked(&mirror, 1).await;
    drop(first);
    mirror.reencode_system_fields();

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert_eq!((report.push.saved, report.push.merged), (1, 0));
    assert!(!report.fetch.full);
    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &group("Work 2")))
    );
}

#[tokio::test]
async fn a_cached_copy_this_build_cannot_project_waits_by_id_instead_of_serving_as_a_base() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = synced(&rig).await;
    let mut left = mirror.metadata();
    left.cache[0].fields = vec![CloudKitField {
        name: "name".to_owned(),
        value: Some(CloudKitValue::Int64(5)),
    }];
    mirror.replace(left);

    rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert!(rig.base(Kind::Group, A).await.is_none());
    assert_eq!(
        rig.held(Kind::Group, A).await.map(|held| held.reason),
        Some(HeldReason::Unreadable)
    );
}

// The Swift metadata no MAC covers never supplies the value of a member the person has not approved.
#[tokio::test]
async fn importing_again_keeps_the_state_file_s_base_of_a_value_waiting_for_the_person() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.internal"}));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
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
    drop(sync);
    let mut forged = mirror.metadata();
    let cached = forged
        .cache
        .iter_mut()
        .find(|cached| cached.name == name(Kind::Connection, A))
        .unwrap();
    for field in &mut cached.fields {
        match field.name.as_str() {
            "host" => field.value = Some(CloudKitValue::Text("evil.example.com".to_owned())),
            "name" => field.value = Some(CloudKitValue::Text("renamed".to_owned())),
            _ => {}
        }
    }
    forged.changes_held_for_unreadable.clear();
    mirror.replace(forged);

    let report = rig.sync_mirrored(&mirror).run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(report.push.saved, 0);
    assert_eq!(
        rig.zone_fields(Kind::Connection, A),
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "prod", "host": "elsewhere.example.com"})
        ))
    );
}
