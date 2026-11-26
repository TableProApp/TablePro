// The iCloud account a pass runs for (0054, Every call is bound to one account): another account deletes the last
// one's state file and starts its own from a full fetch, which sends nothing until the person picks Move my data or
// Start empty (0066, Rules), and an account change during a call saves nothing to either.

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_records::cloudkit::record_type_of;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitTransport};
use tablepro_sync::api::control::{NewIdentityChoice, PassReason, SyncControl, SyncPhase};
use tablepro_sync::api::state::{PushWait, Standing, StateFiles, StateIdentity};

use crate::faults::Flaky;
use crate::support::{A, B, C, D, Rig, USER, cloud_fields, name, projected};

const OTHER: &str = "_9a8b7c";

fn icloud(account: &str) -> StateIdentity {
    StateIdentity::ICloud {
        user_record_name: account.to_owned(),
    }
}

#[tokio::test]
async fn another_account_deletes_the_last_account_s_state_file_and_starts_from_a_full_fetch() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));
    rig.cloud.switch_account(Some(OTHER));

    let switched = sync.run_pass(PassReason::AccountChanged).await.unwrap();
    let phase = sync.status().phase;
    let plan = sync.plan_new_identity().await.unwrap();
    let sent_unasked = rig.zone_fields_of(OTHER, Kind::Connection, A).is_some();
    sync.choose_for_new_identity(NewIdentityChoice::MoveMyData, plan.account.clone())
        .await
        .unwrap();

    assert_eq!(switched.switched_from.as_deref(), Some(USER));
    assert!(switched.zone_made && switched.fetch.full);
    assert_eq!(switched.push_wait, Some(PushWait::AccountChoice { unsent: 1 }));
    assert_eq!((plan.unsent, plan.account.as_str()), (1, OTHER));
    assert_eq!(phase, SyncPhase::NewIdentity);
    assert!(!sent_unasked);
    assert!(!rig.files.exists(&icloud(USER)));
    assert!(rig.files.exists(&icloud(OTHER)));
    assert!(rig.zone_fields_of(OTHER, Kind::Connection, A).is_some());
    assert!(rig.zone_fields_of(OTHER, Kind::Group, B).is_some());
    assert_eq!(sync.account().as_deref(), Some(OTHER));
    assert_eq!(sync.status().phase, SyncPhase::Idle);
}

// Start empty: the synced records leave this device, where the last account's zone keeps them, Local only ones stay,
// and the device fills from the new account. The wait and its count outlive a restart (orchestrator ruling on 0066).
#[tokio::test]
async fn start_empty_leaves_the_synced_records_behind_keeps_local_only_ones_and_fills_from_the_new_account() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Connection).put_with(
        C,
        projected(Kind::Connection, C, &json!({"name": "laptop only"})),
        Standing::LocalOnly,
    );
    rig.cloud.save_elsewhere(
        OTHER,
        record_type_of(Kind::Group).unwrap().name,
        &name(Kind::Group, D),
        cloud_fields(Kind::Group, D, &json!({"name": "Theirs"})),
    );
    rig.cloud.switch_account(Some(OTHER));
    sync.run_pass(PassReason::AccountChanged).await.unwrap();
    let kept = sync.account();
    drop(sync);

    let relaunched = rig.sync(kept.as_deref());
    let after_restart = relaunched.run_pass(PassReason::Launch).await.unwrap();
    let plan = relaunched.plan_new_identity().await.unwrap();
    relaunched
        .choose_for_new_identity(NewIdentityChoice::StartEmpty, plan.account.clone())
        .await
        .unwrap();
    let next = relaunched.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(after_restart.switched_from, None);
    assert_eq!(after_restart.push_wait, Some(PushWait::AccountChoice { unsent: 0 }));
    assert_eq!(plan.unsent, 0);
    assert!(!rig.store(Kind::Connection).holds(A));
    assert!(rig.store(Kind::Connection).holds(C));
    assert!(rig.store(Kind::Group).holds(D));
    assert!(rig.zone_fields_of(OTHER, Kind::Connection, A).is_none());
    assert!(rig.zone_fields_of(OTHER, Kind::Connection, C).is_none());
    assert!(rig.zone_fields(Kind::Connection, A).is_some());
    assert_eq!(next.push_wait, None);
    assert_eq!(next.push.saved, 0);
    assert_eq!(relaunched.status().phase, SyncPhase::Idle);
}

// Start empty keeps the device's settings: the new account's copy wins where it has one, and a category only this
// device holds goes up once the person edits it here (orchestrator ruling).
#[tokio::test]
async fn start_empty_keeps_settings_the_new_account_s_copy_wins_and_an_edit_sends_the_rest() {
    let rig = Rig::new().await;
    let editor = |width: i64| json!({"category": "editor", "options": {"tabWidth": width}});
    let keyboard =
        |key: &str| json!({"category": "keyboard", "options": {"shortcuts": [{"id": key, "value": {"keyCode": 1}}]}});
    let settings = rig.store(Kind::MacosSettings);
    settings.put("editor", projected(Kind::MacosSettings, "editor", &editor(2)));
    settings.put("keyboard", projected(Kind::MacosSettings, "keyboard", &keyboard("b")));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.cloud.save_elsewhere(
        OTHER,
        record_type_of(Kind::MacosSettings).unwrap().name,
        &name(Kind::MacosSettings, "editor"),
        cloud_fields(Kind::MacosSettings, "editor", &editor(8)),
    );
    rig.cloud.switch_account(Some(OTHER));
    sync.run_pass(PassReason::AccountChanged).await.unwrap();

    let plan = sync.plan_new_identity().await.unwrap();
    sync.choose_for_new_identity(NewIdentityChoice::StartEmpty, plan.account.clone())
        .await
        .unwrap();
    sync.run_pass(PassReason::Poll).await.unwrap();
    let kept = settings.fields("keyboard");
    let sent_unedited = rig.zone_fields_of(OTHER, Kind::MacosSettings, "keyboard");
    settings.put("keyboard", projected(Kind::MacosSettings, "keyboard", &keyboard("c")));
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(
        settings.fields("editor"),
        Some(projected(Kind::MacosSettings, "editor", &editor(8)))
    );
    assert_eq!(kept, Some(projected(Kind::MacosSettings, "keyboard", &keyboard("b"))));
    assert!(sent_unedited.is_none());
    assert!(rig.zone_fields_of(OTHER, Kind::MacosSettings, "keyboard").is_some());
    assert!(rig.zone_fields(Kind::MacosSettings, "keyboard").is_some());
    assert_eq!(sync.status().phase, SyncPhase::Idle);
}

// An answer to a prompt shown for one account changes nothing once another account is signed in: a stale Move my data
// never sends the library to the account after it (Codex security round 1).
#[tokio::test]
async fn an_answer_shown_for_another_account_changes_nothing() {
    const THIRD: &str = "_3c2d1e";
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.cloud.switch_account(Some(OTHER));
    sync.run_pass(PassReason::AccountChanged).await.unwrap();
    let shown = sync.plan_new_identity().await.unwrap();
    rig.cloud.switch_account(Some(THIRD));

    let before_the_pass = sync
        .choose_for_new_identity(NewIdentityChoice::MoveMyData, shown.account.clone())
        .await;
    sync.run_pass(PassReason::AccountChanged).await.unwrap();
    let after_the_pass = sync
        .choose_for_new_identity(NewIdentityChoice::MoveMyData, shown.account.clone())
        .await;

    assert_eq!(before_the_pass.unwrap_err().code(), "sync.changed");
    assert_eq!(after_the_pass.unwrap_err().code(), "sync.changed");
    assert!(rig.zone_fields_of(THIRD, Kind::Connection, A).is_none());
    assert!(rig.zone_fields_of(OTHER, Kind::Connection, A).is_none());
    assert_eq!(sync.status().phase, SyncPhase::NewIdentity);
}

#[tokio::test]
async fn move_my_data_is_refused_while_no_account_switch_waits() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();

    let refused = sync
        .choose_for_new_identity(NewIdentityChoice::MoveMyData, USER.to_owned())
        .await;

    assert_eq!(refused.unwrap_err().code(), "sync.not_allowed");
}

#[tokio::test]
async fn an_account_change_between_account_status_and_modify_saves_nothing_to_either_account() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Connection)
        .put(A, projected(Kind::Connection, A, &json!({"name": "mine"})));
    flaky.before_next_modify(Box::new(|cloud| cloud.switch_account_during_next_call(Some(OTHER))));

    let changed = sync.run_pass(PassReason::Poll).await;

    assert_eq!(
        changed.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::AccountChanged)
    );
    assert_eq!(
        rig.zone_fields(Kind::Connection, A),
        Some(projected(Kind::Connection, A, &json!({"name": "prod"})))
    );
    assert!(rig.cloud.record(OTHER, &name(Kind::Connection, A)).is_none());
    assert_eq!(
        rig.base(Kind::Connection, A).await.unwrap().fields,
        Some(projected(Kind::Connection, A, &json!({"name": "prod"})))
    );
}

#[tokio::test]
async fn an_account_change_while_a_fetch_completes_writes_nothing_and_the_next_pass_switches() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work"}));
    let token = rig.token().await;
    rig.cloud.switch_account_during_next_call(Some(OTHER));

    let changed = sync.run_pass(PassReason::CloudKitPush).await;
    let kept = (rig.store(Kind::Group).holds(B), rig.token().await == token);
    let next = sync.run_pass(PassReason::AccountChanged).await.unwrap();

    assert_eq!(
        changed.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::AccountChanged)
    );
    assert_eq!(kept, (false, true));
    assert_eq!(next.switched_from.as_deref(), Some(USER));
    assert!(rig.cloud.record(OTHER, &name(Kind::Group, B)).is_none());
}

// The app was last on another account: the file this account kept from an earlier session is stale, so it goes too,
// and a record deleted here meanwhile is fetched again rather than deleted from the zone.
#[tokio::test]
async fn a_switch_made_while_the_app_was_closed_starts_the_account_afresh() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.sync(None).run_pass(PassReason::Launch).await.unwrap();
    rig.files.open(icloud(OTHER)).await.unwrap();
    rig.store(Kind::Connection).remove(A);

    let relaunched = rig.sync(Some(OTHER));
    let report = relaunched.run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(report.switched_from.as_deref(), Some(OTHER));
    assert!(!rig.files.exists(&icloud(OTHER)));
    assert!(report.fetch.full);
    assert!(rig.store(Kind::Connection).holds(A));
    assert!(rig.zone_fields(Kind::Connection, A).is_some());
}

#[tokio::test]
async fn a_signed_out_device_keeps_its_state_file() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.cloud.switch_account(None);

    let signed_out = sync.run_pass(PassReason::AccountChanged).await;
    rig.cloud.switch_account(Some(USER));
    let back = sync.run_pass(PassReason::AccountChanged).await.unwrap();

    assert_eq!(signed_out.unwrap_err(), SyncError::CloudKit(CloudKitFailure::NoAccount));
    assert!(rig.files.exists(&icloud(USER)));
    assert_eq!(back.switched_from, None);
    assert!(!back.fetch.full);
}
