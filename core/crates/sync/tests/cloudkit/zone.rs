// A removed zone and Upload Again (0054, Rules for both providers): the state is cleared, nothing goes up and the zone
// is not made again until the person asks, after a restart too, and while another device made it again (0066, Rules).

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitOutcome, CloudKitTransport};
use tablepro_sync::api::control::{PassReason, SyncControl, SyncPhase};
use tablepro_sync::api::state::PushWait;
use tablepro_sync::cloudkit::modify::CloudKitSync;

use crate::faults::Flaky;
use crate::support::{A, B, C, Rig, USER, name, projected};

async fn synced(rig: &Rig) -> CloudKitSync {
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    sync
}

fn removed(error: &SyncError) -> bool {
    matches!(
        error,
        SyncError::CloudKit(CloudKitFailure::ZoneDeletedByUser | CloudKitFailure::ZoneNotFound)
    )
}

#[tokio::test]
async fn a_zone_the_person_removed_clears_the_state_and_nothing_goes_up_until_upload_again() {
    let rig = Rig::new().await;
    let sync = synced(&rig).await;
    rig.cloud.remove_zone_by_user(USER);
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));

    let first = sync.run_pass(PassReason::Poll).await.unwrap_err();
    let phase = sync.status().phase;
    let cleared = rig.base(Kind::Connection, A).await.is_none() && rig.token().await.is_none();
    let second = sync.run_pass(PassReason::Person).await.unwrap_err();
    let uploaded = sync.run_upload_again().await.unwrap();

    assert_eq!(first, SyncError::CloudKit(CloudKitFailure::ZoneDeletedByUser));
    assert_eq!(phase, SyncPhase::ZoneRemoved);
    assert!(cleared);
    assert_eq!(second, first);
    assert!(uploaded.zone_made);
    assert_eq!(uploaded.push.saved, 2);
    assert!(rig.zone_fields(Kind::Connection, A).is_some());
    assert!(rig.zone_fields(Kind::Group, B).is_some());
    assert_eq!(sync.status().phase, SyncPhase::Idle);
}

#[tokio::test]
async fn a_removed_zone_stays_removed_after_a_restart() {
    let rig = Rig::new().await;
    let sync = synced(&rig).await;
    rig.cloud.remove_zone_by_user(USER);
    sync.run_pass(PassReason::Poll).await.unwrap_err();
    drop(sync);

    let relaunched = rig.sync(Some(USER));
    let after_restart = relaunched.run_pass(PassReason::Launch).await.unwrap_err();

    assert!(removed(&after_restart));
    assert!(rig.cloud.record(USER, &name(Kind::Connection, A)).is_none());
    assert!(relaunched.run_upload_again().await.is_ok());
    assert!(rig.zone_fields(Kind::Connection, A).is_some());
}

#[tokio::test]
async fn upload_again_is_refused_while_the_zone_is_there() {
    let rig = Rig::new().await;
    let sync = synced(&rig).await;

    let refused = sync.run_upload_again().await;

    assert_eq!(refused.unwrap_err(), SyncError::NotAllowed { what: "upload again" });
}

#[tokio::test]
async fn a_zone_another_device_deleted_counts_as_removed() {
    let rig = Rig::new().await;
    let sync = synced(&rig).await;
    rig.cloud.delete_zone(USER.to_owned()).await.unwrap();

    let gone = sync.run_pass(PassReason::Poll).await.unwrap_err();

    assert_eq!(gone, SyncError::CloudKit(CloudKitFailure::ZoneNotFound));
    assert_eq!(sync.status().phase, SyncPhase::ZoneRemoved);
    assert!(sync.run_pass(PassReason::Poll).await.is_err());
    assert!(rig.cloud.record_names(USER).is_empty());
}

// Another device's Upload Again made the zone again: this one downloads it and sends nothing until its own person
// asks, after a restart too.
#[tokio::test]
async fn a_zone_made_again_elsewhere_is_downloaded_and_waits_for_this_device_s_upload_again() {
    let rig = Rig::new().await;
    let sync = synced(&rig).await;
    rig.cloud.remove_zone_by_user(USER);
    sync.run_pass(PassReason::Poll).await.unwrap_err();
    rig.cloud.ensure_zone(USER.to_owned()).await.unwrap();
    rig.save_elsewhere(Kind::Group, C, &json!({"name": "Home"}));
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));

    let found = sync.run_pass(PassReason::CloudKitPush).await.unwrap();
    let phase = sync.status().phase;
    drop(sync);
    let relaunched = rig.sync(Some(USER));
    let after_restart = relaunched.run_pass(PassReason::Launch).await.unwrap();
    let held_back = rig.zone_fields(Kind::Group, B).is_none();
    let uploaded = relaunched.run_upload_again().await.unwrap();

    assert!(!found.zone_made);
    assert_eq!(found.push_wait, Some(PushWait::UploadAgain));
    assert!(rig.store(Kind::Group).holds(C));
    assert_eq!(phase, SyncPhase::ZoneRemoved);
    assert_eq!(after_restart.push_wait, Some(PushWait::UploadAgain));
    assert!(held_back);
    assert_eq!(uploaded.push_wait, None);
    assert!(rig.zone_fields(Kind::Group, B).is_some());
    assert!(rig.zone_fields(Kind::Connection, A).is_some());
    assert_eq!(relaunched.status().phase, SyncPhase::Idle);
}

#[tokio::test]
async fn a_record_answered_with_a_removed_zone_ends_the_pass_as_a_removed_zone() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));
    flaky.answer_once(
        &name(Kind::Group, B),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, B),
            code: 28,
            retry_after_ms: None,
        },
    );

    let gone = sync.run_pass(PassReason::Poll).await.unwrap_err();

    assert_eq!(gone, SyncError::CloudKit(CloudKitFailure::ZoneDeletedByUser));
    assert_eq!(sync.status().phase, SyncPhase::ZoneRemoved);
    assert!(rig.base(Kind::Connection, A).await.is_none());
}

// A zone this device never saw is made by its first pass, which then sends what the device holds.
#[tokio::test]
async fn a_first_pass_makes_the_zone_and_sends_what_this_device_holds() {
    let rig = Rig::new().await;
    rig.cloud.delete_zone(USER.to_owned()).await.unwrap();
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));

    let first = rig.sync(None).run_pass(PassReason::Launch).await.unwrap();

    assert!(first.zone_made);
    assert!(first.fetch.full);
    assert_eq!(first.push.saved, 1);
    assert!(rig.zone_fields(Kind::Group, B).is_some());
}
