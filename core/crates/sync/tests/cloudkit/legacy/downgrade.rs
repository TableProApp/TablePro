// T-DWN at the engine's side (0054, Verification, the downgrade test): the previous stable takes over from what the
// mirror wrote, after a pass and after offline edits and deletions with the app quit before the next pass. It pushes
// the unsent edits and overwrites nothing newer.

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::cloudkit::CloudKitOutcome;
use tablepro_sync::api::control::PassReason;
use tablepro_sync::engine::JournalEntry;
use tablepro_sync_testing::FakeLegacyMirror;

use super::{PreviousStable, signed_in};
use crate::support::{A, B, C, Rig, name, projected};

fn group(name: &str) -> serde_json::Value {
    json!({"name": name})
}

#[tokio::test]
async fn after_a_pass_the_previous_stable_resumes_at_the_engine_s_token_and_sends_nothing() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    sync.run_pass(PassReason::Poll).await.unwrap();
    drop(sync);
    rig.save_elsewhere(Kind::Group, B, &group("Home 2"));

    let pushed = PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .pass()
    .await;

    assert!(pushed.is_empty());
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
async fn offline_edits_and_deletions_reach_the_previous_stable_when_the_app_quit_before_the_next_pass() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    rig.save_elsewhere(Kind::Group, B, &group("Home"));
    rig.save_elsewhere(Kind::Group, C, &group("Other"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &group("Work 2")));
    rig.store(Kind::Group).remove(B);
    sync.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: vec![B.to_owned()],
    }]);
    sync.flush_legacy_marks().await.unwrap();
    drop(sync);
    rig.save_elsewhere(Kind::Group, C, &group("Other 2"));

    PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .pass()
    .await;

    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &group("Work 2")))
    );
    assert!(rig.zone_fields(Kind::Group, B).is_none());
    assert_eq!(
        rig.zone_fields(Kind::Group, C),
        Some(projected(Kind::Group, C, &group("Other 2")))
    );
    assert_eq!(
        rig.store(Kind::Group).fields(C),
        Some(projected(Kind::Group, C, &group("Other 2")))
    );
    assert!(mirror.metadata().dirty.is_empty() && mirror.metadata().tombstones.is_empty());
}

#[tokio::test]
async fn an_offline_edit_of_a_record_another_device_changed_since_overwrites_nothing() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &group("Work"));
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let sync = rig.sync_mirrored(&mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group).put(A, projected(Kind::Group, A, &group("Mine")));
    sync.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: Vec::new(),
    }]);
    sync.flush_legacy_marks().await.unwrap();
    drop(sync);
    rig.save_elsewhere(Kind::Group, A, &group("Theirs"));

    let pushed = PreviousStable {
        rig: &rig,
        mirror: &mirror,
    }
    .push()
    .await;

    assert!(matches!(
        pushed.as_slice(),
        [CloudKitOutcome::ServerChanged { name: changed, .. }] if *changed == name(Kind::Group, A)
    ));
    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &group("Theirs")))
    );
}
