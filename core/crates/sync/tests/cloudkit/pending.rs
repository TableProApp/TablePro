// The crash window between a store write and the state commit after it (0064, `pending_bases`): a pull the store took
// before the crash is no edit made here, even once the zone changed again before the replay.

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::error::StateError;

use crate::faults::Crashing;
use crate::support::{A, B, Rig, projected};

fn connection(name: &str, port: i64) -> serde_json::Value {
    json!({"name": name, "port": port})
}

// The zone moves the port from 5432 to 6432, and the fetch that takes it stops at its last commit.
async fn crashed_after_the_store_write(rig: &Rig) {
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 6432));
    let crashing = Crashing::new(rig.state.clone());
    crashing.crash_after_commits(1);
    let crashed = rig.fetcher_on(rig.cloud.as_ref(), &crashing).fetch().await;
    assert!(matches!(crashed, Err(SyncError::State(StateError::Io { .. }))));
}

async fn synced(rig: &Rig) {
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 5432));
    rig.fetch().await.unwrap();
}

#[tokio::test]
async fn a_pull_the_store_took_before_a_crash_is_no_edit_when_the_zone_changes_again() {
    let rig = Rig::new().await;
    synced(&rig).await;
    crashed_after_the_store_write(&rig).await;
    let after_crash = rig.store(Kind::Connection).fields(A);
    let staged = rig.pending_bases().await;
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 5432));

    rig.fetch().await.unwrap();
    let pushed = rig.push().await.unwrap();

    let back = projected(Kind::Connection, A, &connection("prod", 5432));
    assert_eq!(
        after_crash,
        Some(projected(Kind::Connection, A, &connection("prod", 6432)))
    );
    assert_eq!(staged.len(), 1);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(back.clone()));
    assert_eq!(pushed.queued, 0);
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(back));
    assert!(rig.pending_bases().await.is_empty());
}

#[tokio::test]
async fn an_edit_merged_with_a_pull_before_a_crash_stays_the_only_edit() {
    let rig = Rig::new().await;
    synced(&rig).await;
    rig.store(Kind::Connection)
        .put(A, projected(Kind::Connection, A, &connection("mine", 5432)));
    crashed_after_the_store_write(&rig).await;
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 5432));

    rig.fetch().await.unwrap();
    rig.push().await.unwrap();

    let mine = projected(Kind::Connection, A, &connection("mine", 5432));
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(mine.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(mine));
}

#[tokio::test]
async fn a_crash_before_the_store_write_leaves_the_edit_against_the_base_it_had() {
    let rig = Rig::new().await;
    synced(&rig).await;
    let mine = projected(Kind::Connection, A, &connection("mine", 5432));
    rig.store(Kind::Connection).put(A, mine.clone());
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 6432));
    let crashing = Crashing::new(rig.state.clone());
    crashing.crash_next_commit();

    let crashed = rig.fetcher_on(rig.cloud.as_ref(), &crashing).fetch().await;
    let after_crash = rig.store(Kind::Connection).fields(A);
    rig.fetch().await.unwrap();
    rig.push().await.unwrap();

    let merged = projected(Kind::Connection, A, &connection("mine", 6432));
    assert!(crashed.is_err());
    assert_eq!(after_crash, Some(mine));
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(merged.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(merged));
}

// Each pending base is judged by its own store: the one written keeps the pull, the one refused stays as it was.
#[tokio::test]
async fn a_store_that_took_its_write_keeps_the_pull_when_another_store_of_the_batch_refused() {
    let rig = Rig::new().await;
    synced(&rig).await;
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work"}));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 6432));
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Office"}));
    rig.store(Kind::Group).refuse_next_write();

    let refused = rig.fetch().await;
    let staged = rig.pending_bases().await.len();
    rig.save_elsewhere(Kind::Connection, A, &connection("prod", 5432));
    rig.fetch().await.unwrap();
    let pushed = rig.push().await.unwrap();

    assert!(matches!(refused, Err(SyncError::Adapter(_))));
    assert_eq!(staged, 2);
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(Kind::Connection, A, &connection("prod", 5432)))
    );
    assert_eq!(
        rig.store(Kind::Group).fields(B),
        Some(projected(Kind::Group, B, &json!({"name": "Office"})))
    );
    assert_eq!(pushed.queued, 0);
}

// A deletion the store took before the crash leaves no base, so nothing reads it as a deletion made here.
#[tokio::test]
async fn a_deletion_the_store_took_before_a_crash_leaves_no_base() {
    let rig = Rig::new().await;
    synced(&rig).await;
    rig.delete_elsewhere(Kind::Connection, A);
    let crashing = Crashing::new(rig.state.clone());
    crashing.crash_after_commits(1);

    let crashed = rig.fetcher_on(rig.cloud.as_ref(), &crashing).fetch().await;
    let held_base = rig.base(Kind::Connection, A).await.is_some();
    rig.fetcher(rig.cloud.as_ref()).settle_pending().await.unwrap();

    assert!(crashed.is_err());
    assert!(held_base);
    assert!(!rig.store(Kind::Connection).holds(A));
    assert!(rig.base(Kind::Connection, A).await.is_none());
    assert!(rig.pending_bases().await.is_empty());
}
