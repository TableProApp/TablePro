// The push and each record's outcome (0054, A push): saves on their base's tag, creates and deletions, the merge of a
// refused save, D12 on `unknownItem`, batches split on `limitExceeded`, a record CloudKit asks to wait, a full iCloud,
// and a crash between CloudKit's answer and the commit of its bases.

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitOutcome};
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::ids::ChangeTag;
use tablepro_sync::api::state::Standing;
use tablepro_sync::engine::JournalEntry;

use crate::faults::{Crashing, Flaky};
use crate::support::{A, B, C, D, Rig, USER, name, projected};

async fn synced(rig: &Rig, kind: Kind, id: &str, wire: &serde_json::Value) {
    rig.save_elsewhere(kind, id, wire);
    rig.fetch().await.unwrap();
}

fn tag_of(rig: &Rig, kind: Kind, id: &str) -> ChangeTag {
    ChangeTag::CloudKit(rig.cloud.record(USER, &name(kind, id)).unwrap().system_fields.unwrap())
}

#[tokio::test]
async fn a_local_edit_goes_up_on_its_base_s_tag_and_the_base_takes_the_new_one() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Connection, A, &json!({"name": "prod", "port": 5432})).await;
    let mine = projected(Kind::Connection, A, &json!({"name": "mine", "port": 5432}));
    rig.store(Kind::Connection).put(A, mine.clone());

    let report = rig.push().await.unwrap();
    let again = rig.push().await.unwrap();

    let base = rig.base(Kind::Connection, A).await.unwrap();
    assert_eq!((report.queued, report.saved), (1, 1));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(mine.clone()));
    assert_eq!(base.tag, tag_of(&rig, Kind::Connection, A));
    assert_eq!(base.fields, Some(mine));
    assert!(base.created_ms.is_some());
    assert_eq!(again.queued, 0);
}

#[tokio::test]
async fn a_record_made_here_goes_up_as_a_create_and_one_removed_here_as_a_deletion() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Group, A, &json!({"name": "Work"})).await;
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Home"})));
    rig.store(Kind::Group).remove(A);

    let report = rig.push().await.unwrap();

    assert_eq!((report.saved, report.deleted), (1, 1));
    assert!(rig.cloud.record(USER, &name(Kind::Group, A)).is_none());
    assert!(rig.zone_fields(Kind::Group, B).is_some());
    assert!(rig.base(Kind::Group, A).await.is_none());
    assert_eq!(
        rig.base(Kind::Group, B).await.unwrap().tag,
        tag_of(&rig, Kind::Group, B)
    );
}

#[tokio::test]
async fn local_only_records_held_records_and_categories_that_are_off_send_nothing() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Connection, B, &json!({"name": "prod"})).await;
    rig.store(Kind::Connection).put_with(
        A,
        projected(Kind::Connection, A, &json!({"name": "local"})),
        Standing::LocalOnly,
    );
    rig.store(Kind::Connection)
        .put(B, projected(Kind::Connection, B, &json!({"name": "edited"})));
    rig.hold_for_approval(Kind::Connection, B).await;
    rig.turn_off(Kind::Group);
    rig.store(Kind::Group)
        .put(C, projected(Kind::Group, C, &json!({"name": "Work"})));

    let report = rig.push().await.unwrap();

    assert_eq!(report.queued, 0);
    assert_eq!(report.calls, 0);
    assert!(rig.cloud.record(USER, &name(Kind::Connection, A)).is_none());
    assert!(rig.cloud.record(USER, &name(Kind::Group, C)).is_none());
}

#[tokio::test]
async fn a_save_refused_with_the_server_s_copy_merges_and_goes_up_on_its_tag() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Connection, A, &json!({"name": "prod", "port": 5432})).await;
    rig.store(Kind::Connection).put(
        A,
        projected(Kind::Connection, A, &json!({"name": "mine", "port": 5432})),
    );
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 6432}));

    let report = rig.push().await.unwrap();

    let merged = projected(Kind::Connection, A, &json!({"name": "mine", "port": 6432}));
    assert_eq!((report.merged, report.saved), (1, 1));
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(merged.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(merged));
    assert_eq!(
        rig.base(Kind::Connection, A).await.unwrap().tag,
        tag_of(&rig, Kind::Connection, A)
    );
}

// D12, the shipped defect: a reorder on one Mac after a deletion on another no longer brings the record back.
#[tokio::test]
async fn a_reorder_of_a_record_deleted_elsewhere_is_dropped_and_a_rename_brings_it_back() {
    let rig = Rig::new().await;
    for id in [A, B] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id, "sort_order": 1}));
    }
    rig.fetch().await.unwrap();
    let renamed = projected(Kind::Connection, A, &json!({"name": "renamed", "sort_order": 1}));
    rig.store(Kind::Connection).put(A, renamed.clone());
    rig.store(Kind::Connection)
        .put(B, projected(Kind::Connection, B, &json!({"name": B, "sort_order": 2})));
    for id in [A, B] {
        rig.delete_elsewhere(Kind::Connection, id);
    }

    let report = rig.push().await.unwrap();

    assert_eq!(report.lost, 2);
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(renamed.clone()));
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(renamed));
    assert!(rig.base(Kind::Connection, A).await.is_some());
    assert!(rig.cloud.record(USER, &name(Kind::Connection, B)).is_none());
    assert!(!rig.store(Kind::Connection).holds(B));
    assert!(rig.base(Kind::Connection, B).await.is_none());
}

#[tokio::test]
async fn a_batch_over_cloudkit_s_limit_goes_again_in_halves() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(200, 2, 2 << 20);
    for id in [A, B, C, D] {
        rig.store(Kind::Group)
            .put(id, projected(Kind::Group, id, &json!({"name": id})));
    }

    let report = rig.push().await.unwrap();

    assert_eq!(report.saved, 4);
    assert!(report.calls > 1);
    for id in [A, B, C, D] {
        assert!(rig.base(Kind::Group, id).await.is_some(), "{id}");
    }
}

#[tokio::test]
async fn a_record_too_large_alone_stays_on_the_device_and_the_rest_go_up() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(200, 400, 4096);
    rig.store(Kind::Connection)
        .put(A, projected(Kind::Connection, A, &json!({"name": "x".repeat(5000)})));
    for id in [B, C] {
        rig.store(Kind::Group)
            .put(id, projected(Kind::Group, id, &json!({"name": id})));
    }

    let report = rig.push().await.unwrap();

    let key = crate::support::key(Kind::Connection, A);
    assert_eq!(report.saved, 2);
    assert_eq!(report.refused, [(key, "sync.icloud.limit_exceeded".to_owned())]);
    assert!(rig.cloud.record(USER, &name(Kind::Connection, A)).is_none());
    assert!(rig.base(Kind::Connection, A).await.is_none());
}

#[tokio::test]
async fn a_record_cloudkit_asks_to_wait_is_not_sent_again_before_its_wait_ends() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    flaky.answer_once(
        &name(Kind::Group, A),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, A),
            code: 7,
            retry_after_ms: Some(30_000),
        },
    );

    let throttled = rig.push_through(flaky.as_ref()).await.unwrap();
    rig.clock.advance(10_000);
    let early = rig.push_through(flaky.as_ref()).await.unwrap();
    rig.clock.advance(20_000);
    let after = rig.push_through(flaky.as_ref()).await.unwrap();

    assert!(throttled.throttled);
    assert_eq!(throttled.retry_after_ms, Some(30_000));
    assert_eq!(throttled.failed, [(crate::support::key(Kind::Group, A), Some(7))]);
    assert_eq!((early.queued, early.calls), (0, 0));
    assert_eq!(after.saved, 1);
    assert!(rig.zone_fields(Kind::Group, A).is_some());
}

#[tokio::test]
async fn a_full_icloud_stops_the_upload_and_keeps_what_landed_before_it() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    for id in [A, B] {
        rig.store(Kind::Group)
            .put(id, projected(Kind::Group, id, &json!({"name": id})));
    }
    flaky.answer_once(
        &name(Kind::Group, B),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, B),
            code: 25,
            retry_after_ms: None,
        },
    );

    let stopped = rig.push_through(flaky.as_ref()).await;

    assert_eq!(
        stopped.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::QuotaExceeded)
    );
    assert!(rig.base(Kind::Group, A).await.is_some());
    assert!(rig.base(Kind::Group, B).await.is_none());
}

// CloudKit took the save, then the process stopped before its base was committed: the next push meets its own save as
// the server's copy and settles on it.
#[tokio::test]
async fn a_save_cloudkit_took_before_a_crash_settles_on_the_next_push() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Connection, A, &json!({"name": "prod"})).await;
    let mine = projected(Kind::Connection, A, &json!({"name": "mine"}));
    rig.store(Kind::Connection).put(A, mine.clone());
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));
    let crashing = Crashing::new(rig.state.clone());
    crashing.crash_next_commit();

    let crashed = rig.push_on(rig.cloud.as_ref(), &crashing).await;
    let kept_base = rig.base(Kind::Connection, A).await.unwrap().fields;
    let report = rig.push().await.unwrap();
    let again = rig.push().await.unwrap();

    assert!(crashed.is_err());
    assert_eq!(
        kept_base,
        Some(projected(Kind::Connection, A, &json!({"name": "prod"})))
    );
    assert_eq!(report.merged, 2);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(mine.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(mine));
    assert_eq!(
        rig.base(Kind::Group, B).await.unwrap().tag,
        tag_of(&rig, Kind::Group, B)
    );
    assert_eq!(rig.cloud.record_names(USER).len(), 2);
    assert_eq!(again.queued, 0);
}

#[tokio::test]
async fn an_answer_left_out_leaves_the_record_for_a_later_push() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    flaky.leave_unanswered(&name(Kind::Group, A));

    let unanswered = rig.push_through(flaky.as_ref()).await.unwrap();
    let based = rig.base(Kind::Group, A).await.is_some();
    rig.push().await.unwrap();

    assert_eq!(unanswered.failed, [(crate::support::key(Kind::Group, A), None)]);
    assert!(!based);
    assert_eq!(
        rig.base(Kind::Group, A).await.unwrap().tag,
        tag_of(&rig, Kind::Group, A)
    );
}

#[tokio::test]
async fn a_long_id_goes_up_under_the_digest_the_zone_names_it_with() {
    let rig = Rig::new().await;
    let category =
        tablepro_records::record_id::column_layout_category(uuid::Uuid::nil(), Some("shop"), None, &"t".repeat(240));
    let wire = tablepro_records::record_id::shortened(Kind::MacosSettings, category.clone());
    let layout = json!({"category": category, "options": {"columnWidths": [{"id": "id", "value": 80}]}});
    rig.store(Kind::MacosSettings)
        .put(&category, projected(Kind::MacosSettings, &wire, &layout));

    let report = rig.push().await.unwrap();
    let again = rig.push().await.unwrap();

    assert_eq!(report.saved, 1);
    assert!(rig.cloud.record(USER, &name(Kind::MacosSettings, &wire)).is_some());
    assert!(rig.base(Kind::MacosSettings, &wire).await.is_some());
    assert_eq!(again.queued, 0);
}

// A pass a journal signal started sends only the records the journal named (0060).
#[tokio::test]
async fn a_journal_pass_sends_only_what_the_journal_named() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    for id in [A, B] {
        rig.store(Kind::Group)
            .put(id, projected(Kind::Group, id, &json!({"name": id})));
    }
    sync.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: Vec::new(),
    }]);

    let journal = sync.run_pass(PassReason::Journal).await.unwrap();
    let full = sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(journal.push.saved, 1);
    assert!(rig.zone_fields(Kind::Group, A).is_some());
    assert_eq!(full.push.saved, 1);
    assert!(rig.zone_fields(Kind::Group, B).is_some());
}

#[tokio::test]
async fn a_transport_that_drops_the_call_keeps_every_base() {
    let rig = Rig::new().await;
    synced(&rig, Kind::Group, A, &json!({"name": "Work"})).await;
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Home"})));
    rig.cloud.fail_next(CloudKitFailure::Network);

    let failed = rig.push().await;

    assert_eq!(failed.unwrap_err(), SyncError::CloudKit(CloudKitFailure::Network));
    assert_eq!(
        rig.base(Kind::Group, A).await.unwrap().fields,
        Some(projected(Kind::Group, A, &json!({"name": "Work"})))
    );
}

// A profile's deletion unlinks connections and removes Keychain secrets, so one the zone lost is not deleted by a save's
// answer: it keeps its base until the deletion comes through the changes, and is not sent again meanwhile.
#[tokio::test]
async fn a_profile_answered_unknown_item_keeps_its_base_and_is_not_sent_again_in_the_pass() {
    let rig = Rig::new().await;
    synced(&rig, Kind::SshProfile, A, &json!({"name": "bastion", "host": "jump"})).await;
    rig.store(Kind::SshProfile).put(
        A,
        projected(Kind::SshProfile, A, &json!({"name": "bastion", "host": "jump2"})),
    );
    rig.delete_elsewhere(Kind::SshProfile, A);

    let report = rig.push().await.unwrap();

    assert_eq!((report.lost, report.calls), (1, 1));
    assert!(rig.store(Kind::SshProfile).holds(A));
    assert!(rig.base(Kind::SshProfile, A).await.is_some());
    assert!(rig.cloud.record(USER, &name(Kind::SshProfile, A)).is_none());
}
