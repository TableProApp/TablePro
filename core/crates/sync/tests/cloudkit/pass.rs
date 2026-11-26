// The iCloud pass as the scheduler runs it (0054, Scheduling): a wait CloudKit names for a record holds the next pass
// back, and a category turned on is read whole.

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitOutcome, CloudKitTransport};
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::state::StateFiles;
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::engine::Pass;
use tablepro_sync::state::SqliteStateFiles;
use tokio::time::timeout;

use crate::faults::{Flaky, Unreliable};
use crate::support::{A, B, KINDS, Rig, name, projected};

#[tokio::test]
async fn a_wait_cloudkit_names_for_a_record_it_could_not_return_reaches_the_fetch_report() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_reads(&name(Kind::Group, A), 1);
    transport.wait_on_failed_reads(5_000);

    let report = rig.fetch_through(&transport).await.unwrap();

    assert_eq!(report.retry_after_ms, Some(5_000));
    assert!(rig.held(Kind::Group, A).await.is_some());
}

#[tokio::test]
async fn a_wait_cloudkit_names_for_a_record_holds_the_next_pass_back_as_a_throttle() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    flaky.answer_once(
        &name(Kind::Group, A),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, A),
            code: 23,
            retry_after_ms: Some(30_000),
        },
    );

    let throttled = sync.pass(PassReason::Poll).await;
    let next = sync.pass(PassReason::Person).await;

    assert_eq!(
        throttled.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::Throttled {
            retry_after_ms: Some(30_000)
        })
    );
    assert!(next.is_ok());
    assert!(rig.zone_fields(Kind::Group, A).is_none());
}

// A delta never sends again what earlier fetches passed over, so a category turned on is read whole.
#[tokio::test]
async fn a_category_turned_on_is_read_whole_on_the_next_pass() {
    let rig = Rig::new().await;
    rig.turn_off(Kind::Group);
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let skipped = !rig.store(Kind::Group).holds(B);
    sync.run_pass(PassReason::Poll).await.unwrap();

    sync.set_categories(Categories::new(KINDS)).await.unwrap();
    let report = sync.run_pass(PassReason::Person).await.unwrap();

    assert!(skipped);
    assert!(report.fetch.full);
    assert!(rig.store(Kind::Group).holds(B));
}

// The state file on disk keeps one connection, so a batch's two commits around its store write, the push's commits and
// the zone's row each run with no other transaction open.
#[tokio::test]
async fn a_pass_over_the_state_file_on_disk_commits_around_its_store_writes() {
    let rig = Rig::new().await;
    let dir = tempfile::tempdir().unwrap();
    let files: Arc<dyn StateFiles> = Arc::new(SqliteStateFiles::at(dir.path().to_path_buf()));
    let sync = rig.sync_over(Arc::clone(&rig.cloud) as Arc<dyn CloudKitTransport>, files, None);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 5432}));
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));

    let first = timeout(Duration::from_secs(30), sync.run_pass(PassReason::Launch))
        .await
        .unwrap()
        .unwrap();
    rig.store(Kind::Connection).put(
        A,
        projected(Kind::Connection, A, &json!({"name": "mine", "port": 5432})),
    );
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 6432}));
    let second = timeout(Duration::from_secs(30), sync.run_pass(PassReason::Poll))
        .await
        .unwrap()
        .unwrap();

    let merged = projected(Kind::Connection, A, &json!({"name": "mine", "port": 6432}));
    assert_eq!((first.fetch.counts.written, first.push.saved), (1, 1));
    assert_eq!(second.push.saved, 1);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(merged.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(merged));
}
