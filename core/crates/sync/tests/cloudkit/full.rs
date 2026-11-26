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
    // A record older than the deleted ones that the zone still holds: this is the zone the bases came from.
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "oldest"}));
    for id in [A, B, C] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.save_elsewhere(Kind::SshProfile, D, &json!({"name": "bastion"}));
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.save_elsewhere(Kind::Group, D, &json!({"name": "stays"}));
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

// A zone deleted and made again holds only records created after it was made: the copies this device had, all
// older than any record the fetch returned, are not proven deleted (Swift's `SyncFullFetchDeletions`).
#[tokio::test]
async fn a_full_fetch_of_a_zone_made_again_proves_no_older_record_deleted() {
    let rig = Rig::new().await;
    for id in [A, B] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    for id in [A, B] {
        rig.delete_elsewhere(Kind::Connection, id);
    }
    rig.save_elsewhere(Kind::Group, D, &json!({"name": "made after"}));
    rig.cloud.expire_tokens(USER);

    let report = rig.fetch().await.unwrap();

    assert!(report.full);
    assert_eq!(report.counts.inferred, 0);
    assert!(rig.store(Kind::Connection).holds(A) && rig.store(Kind::Connection).holds(B));
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

// A zone made again elsewhere, or a short answer, lists nothing it held: that proves no deletion.
#[tokio::test]
async fn a_full_fetch_that_lists_nothing_deletes_nothing() {
    let rig = Rig::new().await;
    for id in [A, B] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    for id in [A, B] {
        rig.delete_elsewhere(Kind::Connection, id);
    }
    rig.cloud.expire_tokens(USER);

    let report = rig.fetch().await.unwrap();

    assert!(report.full);
    assert_eq!(report.counts.inferred, 0);
    assert!(rig.store(Kind::Connection).holds(A) && rig.store(Kind::Connection).holds(B));
}

// Saved queries and table favourites share a file. Restored while favourites are off, the saved queries refill at
// once and the favourites once they are on, each from its own row.
#[tokio::test]
async fn kinds_that_share_a_restored_store_each_refill_when_their_category_is_on() {
    let rig = Rig::new().await;
    let favourite = tablepro_records::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id;
    let query = |name: &str| json!({"name": name, "query": "SELECT 1"});
    let table = |name: &str| json!({"connection_id": A, "database": "shop", "name": "orders", "schema": name});
    rig.save_elsewhere(Kind::SavedQuery, B, &query("top"));
    rig.save_elsewhere(Kind::FavouriteTable, &favourite, &table("public"));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::FavouriteTable);
    rig.store(Kind::SavedQuery)
        .restore(vec![(B, projected(Kind::SavedQuery, B, &query("stale")))]);
    rig.store(Kind::FavouriteTable).restore(vec![(
        &favourite,
        projected(Kind::FavouriteTable, &favourite, &table("stale")),
    )]);

    let first = rig.fetch().await.unwrap();
    let again = rig.fetch().await.unwrap();
    rig.turn_on(Kind::FavouriteTable);
    let on = rig.fetch().await.unwrap();

    assert_eq!(first.refilled, [Kind::SavedQuery]);
    assert!(again.refilled.is_empty());
    assert_eq!(on.refilled, [Kind::FavouriteTable]);
    assert_eq!(
        rig.store(Kind::SavedQuery).fields(B),
        Some(projected(Kind::SavedQuery, B, &query("top")))
    );
    assert_eq!(
        rig.store(Kind::FavouriteTable).fields(&favourite),
        Some(projected(Kind::FavouriteTable, &favourite, &table("public")))
    );
}

// 0066, `deferred` and `stores_kinds`: favourites off while their shared file refills keep the copy the restore left,
// so once on they merge against it. An edit made here meanwhile stays, and what was not edited takes the zone's copy.
#[tokio::test]
async fn a_kind_off_while_its_store_refills_merges_its_later_edits_against_the_restored_copy() {
    let rig = Rig::new().await;
    let favourite =
        |name: &str| tablepro_records::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, name).id;
    let (edited, untouched) = (favourite("orders"), favourite("users"));
    let table =
        |name: &str, schema: &str| json!({"connection_id": A, "database": "shop", "name": name, "schema": schema});
    rig.save_elsewhere(Kind::SavedQuery, B, &json!({"name": "top", "query": "SELECT 1"}));
    rig.save_elsewhere(Kind::FavouriteTable, &edited, &table("orders", "public"));
    rig.save_elsewhere(Kind::FavouriteTable, &untouched, &table("users", "public"));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::FavouriteTable);
    rig.store(Kind::FavouriteTable).restore(vec![
        (
            &edited,
            projected(Kind::FavouriteTable, &edited, &table("orders", "public")),
        ),
        (
            &untouched,
            projected(Kind::FavouriteTable, &untouched, &table("users", "stale")),
        ),
    ]);
    let sibling = rig.fetch().await.unwrap();
    let kept = rig.deferred(Kind::FavouriteTable, &edited).await.is_some();
    rig.store(Kind::FavouriteTable).put(
        &edited,
        projected(Kind::FavouriteTable, &edited, &table("orders", "mine")),
    );

    rig.turn_on(Kind::FavouriteTable);
    let on = rig.fetch().await.unwrap();

    assert_eq!(sibling.refilled, [Kind::SavedQuery]);
    assert!(kept);
    assert_eq!(on.refilled, [Kind::FavouriteTable]);
    assert_eq!(
        rig.store(Kind::FavouriteTable).fields(&edited),
        Some(projected(Kind::FavouriteTable, &edited, &table("orders", "mine")))
    );
    assert_eq!(
        rig.store(Kind::FavouriteTable).fields(&untouched),
        Some(projected(Kind::FavouriteTable, &untouched, &table("users", "public")))
    );
    assert!(rig.deferred(Kind::FavouriteTable, &edited).await.is_none());
}

// A kept copy is no deletion: a full fetch that lists nothing proves none, whatever the refill kept.
#[tokio::test]
async fn a_copy_kept_while_off_deletes_nothing_on_a_full_fetch_that_lists_nothing() {
    let rig = Rig::new().await;
    let favourite = tablepro_records::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id;
    rig.save_elsewhere(
        Kind::FavouriteTable,
        &favourite,
        &json!({"connection_id": A, "database": "shop", "name": "orders"}),
    );
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::FavouriteTable);
    let mut txn = rig.state.begin().await.unwrap();
    let Some(Row::Scope(scope)) = txn.get(&RowKey::Scope(ScopeName::Personal)).await.unwrap() else {
        panic!("no scope row");
    };
    txn.put(Row::Scope(ScopeRow { refill: true, ..scope })).await.unwrap();
    txn.commit().await.unwrap();
    rig.fetch().await.unwrap();
    let kept = rig.deferred(Kind::FavouriteTable, &favourite).await.is_some();
    rig.delete_elsewhere(Kind::FavouriteTable, &favourite);

    rig.turn_on(Kind::FavouriteTable);
    let on = rig.fetch().await.unwrap();

    assert!(kept);
    assert!(on.full);
    assert!(rig.store(Kind::FavouriteTable).holds(&favourite));
}

// The copy stands for the store the restore left: a later refill of another store never takes it again, so an edit made
// meanwhile still reads as an edit once the kind is on (Codex review round 2).
#[tokio::test]
async fn a_copy_kept_while_off_is_not_taken_again_when_another_store_refills() {
    let rig = Rig::new().await;
    let favourite = tablepro_records::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id;
    let table = |schema: &str| json!({"connection_id": A, "database": "shop", "name": "orders", "schema": schema});
    rig.save_elsewhere(Kind::FavouriteTable, &favourite, &table("public"));
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::FavouriteTable);
    rig.store(Kind::FavouriteTable).restore(vec![(
        &favourite,
        projected(Kind::FavouriteTable, &favourite, &table("public")),
    )]);
    rig.fetch().await.unwrap();
    rig.store(Kind::FavouriteTable)
        .put(&favourite, projected(Kind::FavouriteTable, &favourite, &table("mine")));
    rig.store(Kind::Group)
        .restore(vec![(B, projected(Kind::Group, B, &json!({"name": "Work"})))]);
    let other = rig.fetch().await.unwrap();

    rig.turn_on(Kind::FavouriteTable);
    rig.fetch().await.unwrap();

    assert_eq!(other.refilled, [Kind::Group]);
    assert_eq!(
        rig.store(Kind::FavouriteTable).fields(&favourite),
        Some(projected(Kind::FavouriteTable, &favourite, &table("mine")))
    );
}

// The pull wins over what iCloud carries; a field only this device keeps stays.
#[tokio::test]
async fn a_refill_keeps_the_fields_icloud_does_not_carry() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let mut stale = projected(Kind::Connection, A, &json!({"name": "stale"}));
    stale["last_opened_at"] = json!(1_700_000_000_000_i64);
    rig.store(Kind::Connection).restore(vec![(A, stale)]);

    rig.fetch().await.unwrap();

    let mut expected = projected(Kind::Connection, A, &json!({"name": "prod"}));
    expected["last_opened_at"] = json!(1_700_000_000_000_i64);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(expected));
}

#[tokio::test]
async fn a_scope_refill_leaves_a_kind_that_is_off_to_refill_once_it_is_on() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Tag, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    rig.turn_off(Kind::Tag);
    rig.store(Kind::Tag)
        .put(A, projected(Kind::Tag, A, &json!({"name": "stale"})));
    let mut txn = rig.state.begin().await.unwrap();
    let Some(Row::Scope(scope)) = txn.get(&RowKey::Scope(ScopeName::Personal)).await.unwrap() else {
        panic!("no scope row");
    };
    txn.put(Row::Scope(ScopeRow { refill: true, ..scope })).await.unwrap();
    txn.commit().await.unwrap();

    let while_off = rig.fetch().await.unwrap();
    rig.turn_on(Kind::Tag);
    let on = rig.fetch().await.unwrap();

    assert!(!while_off.refilled.contains(&Kind::Tag));
    assert_eq!(on.refilled, [Kind::Tag]);
    assert_eq!(
        rig.store(Kind::Tag).fields(A),
        Some(projected(Kind::Tag, A, &json!({"name": "prod"})))
    );
}

// Time Machine puts a shared file back within its generation: every kind it keeps refills, written by the last pull
// or not.
#[tokio::test]
async fn a_rollback_of_a_shared_store_refills_each_kind_it_keeps() {
    let rig = Rig::new().await;
    let favourite = tablepro_records::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id;
    let table = json!({"connection_id": A, "database": "shop", "name": "orders"});
    rig.save_elsewhere(Kind::FavouriteTable, &favourite, &table);
    rig.fetch().await.unwrap();
    let at_favourite = rig.store(Kind::FavouriteTable).sequence();
    for id in [B, C, D] {
        rig.save_elsewhere(Kind::SavedQuery, id, &json!({"name": id, "query": "SELECT 1"}));
        rig.fetch().await.unwrap();
    }
    rig.store(Kind::FavouriteTable).roll_back(at_favourite, Vec::new());

    let report = rig.fetch().await.unwrap();

    assert!(report.refilled.contains(&Kind::FavouriteTable));
    assert!(rig.store(Kind::FavouriteTable).holds(&favourite));
}
