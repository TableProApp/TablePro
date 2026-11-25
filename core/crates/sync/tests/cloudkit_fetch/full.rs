use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::state::{Row, RowKey, ScopeRow, Standing};
use tablepro_sync::cloudkit::fetch::read_everything_again;

use crate::faults::Unreliable;
use crate::support::{A, B, C, D, Rig, USER, name, projected};

#[tokio::test]
async fn a_deletion_for_a_category_that_is_off_waits_until_a_full_fetch_reads_the_category() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::Tag);
    rig.delete_elsewhere(Kind::Tag, A);

    let off = rig.fetch().await.unwrap();
    let waiting = rig.deferred(Kind::Tag, A).await;
    rig.turn_on(Kind::Tag);
    rig.fetch().await.unwrap();
    let after_a_delta = rig.store(Kind::Tag).holds(A);
    read_everything_again(rig.state.as_ref()).await.unwrap();
    let full = rig.fetch().await.unwrap();

    assert_eq!(off.counts.deferred, 1);
    assert!(waiting.is_some());
    assert!(after_a_delta);
    assert!(full.full);
    assert!(!rig.store(Kind::Tag).holds(A));
    assert!(rig.deferred(Kind::Tag, A).await.is_none());
    assert!(rig.base(Kind::Tag, A).await.is_none());
}

#[tokio::test]
async fn a_deferred_deletion_of_a_record_saved_again_settles_without_applying() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::Tag);
    rig.delete_elsewhere(Kind::Tag, A);
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "made again"}));

    let off = rig.fetch().await.unwrap();
    let waiting = rig.deferred(Kind::Tag, A).await;
    rig.turn_on(Kind::Tag);
    read_everything_again(rig.state.as_ref()).await.unwrap();
    rig.fetch().await.unwrap();

    assert_eq!(off.counts.skipped, 1);
    assert!(waiting.is_none());
    assert_eq!(
        rig.store(Kind::Tag).fields(A),
        Some(projected(Kind::Tag, A, &json!({"name": "made again"})))
    );
}

#[tokio::test]
async fn a_profile_deleted_while_its_category_was_off_is_never_deleted_late() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::SshProfile, D, &json!({"name": "bastion"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::SshProfile);
    rig.delete_elsewhere(Kind::SshProfile, D);
    rig.fetch().await.unwrap();
    rig.turn_on(Kind::SshProfile);
    read_everything_again(rig.state.as_ref()).await.unwrap();

    let full = rig.fetch().await.unwrap();

    assert!(full.full);
    assert_eq!(full.counts.inferred, 0);
    assert!(rig.store(Kind::SshProfile).holds(D));
    assert!(rig.deferred(Kind::SshProfile, D).await.is_none());
}

// A deletion the expired token passed is found by what the full fetch no longer lists. A content edit here revives
// the record as a create, a Local only copy stays, a profile is never deleted late, and a category that is off keeps
// its records.
#[tokio::test]
async fn a_full_fetch_treats_a_record_it_did_not_return_as_deleted() {
    let rig = Rig::new().await;
    for id in [A, B, C] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.save_elsewhere(Kind::SshProfile, D, &json!({"name": "bastion"}));
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let edited = projected(Kind::Connection, B, &json!({"name": "edited here"}));
    rig.store(Kind::Connection).put(B, edited.clone());
    let local_only = projected(Kind::Connection, C, &json!({"name": C}));
    rig.store(Kind::Connection).put_with(C, local_only, Standing::LocalOnly);
    for id in [A, B, C] {
        rig.delete_elsewhere(Kind::Connection, id);
    }
    rig.delete_elsewhere(Kind::SshProfile, D);
    rig.delete_elsewhere(Kind::Tag, A);
    rig.turn_off(Kind::Tag);
    rig.cloud.expire_tokens(USER);

    let report = rig.fetch().await.unwrap();

    assert!(report.token_expired && report.full);
    assert_eq!(report.counts.inferred, 3);
    assert!(!rig.store(Kind::Connection).holds(A));
    assert_eq!(rig.store(Kind::Connection).fields(B), Some(edited));
    assert!(rig.base(Kind::Connection, B).await.is_none());
    assert!(rig.store(Kind::Connection).holds(C));
    assert!(rig.store(Kind::SshProfile).holds(D));
    assert!(rig.store(Kind::Tag).holds(A));
    assert!(rig.base(Kind::Tag, A).await.is_some());
}

#[tokio::test]
async fn a_record_a_full_fetch_listed_but_could_not_read_is_not_taken_as_deleted() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a 2"}));
    rig.cloud.expire_tokens(USER);
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_reads(&name(Kind::Group, A), 10);

    let report = rig.fetch_through(&transport).await.unwrap();

    assert!(report.full);
    assert_eq!(report.counts.inferred, 0);
    assert!(rig.store(Kind::Group).holds(A));
    assert!(rig.held(Kind::Group, A).await.is_some());
}

// The store went back in time: the zone's copy wins over what it kept, what the zone deleted goes, and a record the
// zone never saw stays and goes up as a create.
#[tokio::test]
async fn a_restored_store_refills_from_a_full_fetch_the_pull_wins() {
    let rig = Rig::new().await;
    for id in [A, B, D] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    rig.delete_elsewhere(Kind::Connection, D);
    let fields = |id: &str, name: &str| projected(Kind::Connection, id, &json!({"name": name}));
    rig.store(Kind::Connection).restore(vec![
        (A, fields(A, "stale")),
        (C, fields(C, "new here")),
        (D, fields(D, D)),
    ]);

    let report = rig.fetch().await.unwrap();
    let next = rig.fetch().await.unwrap();

    let store = rig.store(Kind::Connection);
    assert!(report.full);
    assert_eq!(report.refilled, [Kind::Connection]);
    assert_eq!(store.fields(A), Some(fields(A, A)));
    assert_eq!(store.fields(B), Some(fields(B, B)));
    assert_eq!(store.fields(C), Some(fields(C, "new here")));
    assert!(rig.base(Kind::Connection, C).await.is_none());
    assert!(!store.holds(D));
    assert!(rig.base(Kind::Connection, D).await.is_none());
    assert_eq!(
        rig.store_row(Kind::Connection).await.unwrap().generation,
        rig.store(Kind::Connection).generation()
    );
    assert!(!next.full && next.refilled.is_empty());
}

#[tokio::test]
async fn a_store_restored_while_its_category_is_off_refills_once_the_category_is_on() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::Tag);
    rig.store(Kind::Tag)
        .restore(vec![(A, projected(Kind::Tag, A, &json!({"name": "stale"})))]);

    let off = rig.fetch().await.unwrap();
    rig.turn_on(Kind::Tag);
    let on = rig.fetch().await.unwrap();

    assert!(off.refilled.is_empty() && !off.full);
    assert_eq!(on.refilled, [Kind::Tag]);
    assert_eq!(
        rig.store(Kind::Tag).fields(A),
        Some(projected(Kind::Tag, A, &json!({"name": "prod"})))
    );
}

#[tokio::test]
async fn a_scope_in_refill_reads_the_whole_zone_and_leaves_refill_once_it_did() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.fetch().await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "kept here"})));
    let mut txn = rig.state.begin().await.unwrap();
    let Some(Row::Scope(scope)) = txn.get(&RowKey::Scope(ScopeName::Personal)).await.unwrap() else {
        panic!("no scope row");
    };
    txn.put(Row::Scope(ScopeRow { refill: true, ..scope })).await.unwrap();
    txn.commit().await.unwrap();

    let report = rig.fetch().await.unwrap();

    let Some(Row::Scope(scope)) = rig
        .state
        .begin()
        .await
        .unwrap()
        .get(&RowKey::Scope(ScopeName::Personal))
        .await
        .unwrap()
    else {
        panic!("no scope row");
    };
    assert!(report.full);
    assert!(!scope.refill);
    assert_eq!(
        rig.store(Kind::Group).fields(A),
        Some(projected(Kind::Group, A, &json!({"name": "a"})))
    );
}
