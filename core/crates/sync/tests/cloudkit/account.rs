// The iCloud account a pass runs for (0054, Every call is bound to one account): another account deletes the last
// one's state file and starts its own from a full fetch, and an account change during a call saves nothing to either.

use std::sync::Arc;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitTransport};
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::state::{StateFiles, StateIdentity};

use crate::faults::Flaky;
use crate::support::{A, B, Rig, USER, name, projected};

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
    rig.cloud.switch_account(Some(OTHER));

    let switched = sync.run_pass(PassReason::AccountChanged).await.unwrap();

    assert_eq!(switched.switched_from.as_deref(), Some(USER));
    assert!(switched.zone_made && switched.fetch.full);
    assert!(!rig.files.exists(&icloud(USER)));
    assert!(rig.files.exists(&icloud(OTHER)));
    assert!(rig.zone_fields_of(OTHER, Kind::Connection, A).is_some());
    assert_eq!(sync.account().await.as_deref(), Some(OTHER));
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
