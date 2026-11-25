use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::cloudkit::{CloudKitField, CloudKitValue};
use tablepro_sync::api::state::{HeldReason, Standing};

use crate::faults::Unreliable;
use crate::support::{A, B, C, D, Rig, USER, name, projected};

#[tokio::test]
async fn a_change_to_a_copy_this_build_cannot_read_is_held_then_fetched_by_name_once_it_reads() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let prod = projected(Kind::Connection, A, &json!({"name": "prod"}));
    rig.store(Kind::Connection).make_unreadable(A);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "renamed"}));

    let held = rig.fetch().await.unwrap();
    let row = rig.held(Kind::Connection, A).await.unwrap();
    let base_while_held = rig.base(Kind::Connection, A).await.unwrap().fields;
    rig.store(Kind::Connection).put(A, prod.clone());
    let recovered = rig.fetch().await.unwrap();

    let renamed = projected(Kind::Connection, A, &json!({"name": "renamed"}));
    assert_eq!(held.counts.held, 1);
    assert_eq!(row.reason, HeldReason::Unreadable);
    assert_eq!(row.record.fields, Some(renamed.clone()));
    assert_eq!(base_while_held, Some(prod));
    assert_eq!(recovered.counts.recovered, 1);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(renamed.clone()));
    assert_eq!(rig.base(Kind::Connection, A).await.unwrap().fields, Some(renamed));
    assert!(rig.held(Kind::Connection, A).await.is_none());
}

#[tokio::test]
async fn a_local_only_copy_takes_no_pulled_change_and_keeps_its_record_when_deleted_elsewhere() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let kept = projected(Kind::Connection, A, &json!({"name": "on this Mac"}));
    rig.store(Kind::Connection)
        .put_with(A, kept.clone(), Standing::LocalOnly);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "renamed"}));

    rig.fetch().await.unwrap();
    let after_change = rig.store(Kind::Connection).fields(A);
    let base_after_change = rig.base(Kind::Connection, A).await.unwrap().fields;
    rig.delete_elsewhere(Kind::Connection, A);
    rig.fetch().await.unwrap();

    assert_eq!(after_change, Some(kept.clone()));
    assert_eq!(
        base_after_change,
        Some(projected(Kind::Connection, A, &json!({"name": "prod"})))
    );
    assert!(rig.held(Kind::Connection, A).await.is_none());
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(kept));
    assert!(rig.base(Kind::Connection, A).await.is_none());
}

// A copy it cannot read goes by its id when its standing says it syncs, a Local only one stays, and one with no
// standing waits for a build that reads it, then follows the rules a readable record has.
#[tokio::test]
async fn a_deletion_of_a_copy_this_build_cannot_read_follows_its_standing() {
    let rig = Rig::new().await;
    let store = rig.store(Kind::Connection);
    let fields = |id: &str| projected(Kind::Connection, id, &json!({"name": id}));
    store.put(A, fields(A));
    store.put_with(B, fields(B), Standing::LocalOnly);
    for id in [A, B, C] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    for id in [A, B, C] {
        store.make_unreadable(id);
        rig.delete_elsewhere(Kind::Connection, id);
    }

    rig.fetch().await.unwrap();
    let held = rig.held(Kind::Connection, C).await.unwrap();
    let c_kept = store.holds(C);
    store.put(C, fields(C));
    rig.fetch().await.unwrap();

    assert!(!store.holds(A));
    assert!(store.holds(B));
    assert!(held.record.deleted.is_some());
    assert!(c_kept);
    assert!(!store.holds(C));
    assert!(rig.held(Kind::Connection, C).await.is_none());
    assert!(rig.base(Kind::Connection, C).await.is_none());
}

#[tokio::test]
async fn a_profile_s_deletion_waits_for_a_build_that_reads_it() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::SshProfile, D, &json!({"name": "bastion", "host": "jump"}));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::SshProfile, D, &json!({"name": "bastion 2", "host": "jump"}));
    rig.fetch().await.unwrap();
    rig.store(Kind::SshProfile).make_unreadable(D);
    rig.delete_elsewhere(Kind::SshProfile, D);

    rig.fetch().await.unwrap();

    assert!(rig.store(Kind::SshProfile).holds(D));
    assert!(rig.held(Kind::SshProfile, D).await.unwrap().record.deleted.is_some());
}

#[tokio::test]
async fn a_record_the_zone_lists_but_cannot_return_is_fetched_by_name_and_held_while_that_fails() {
    let rig = Rig::new().await;
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_reads(&name(Kind::Group, A), 2);
    for id in [A, B] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }

    rig.fetch_through(&transport).await.unwrap();
    let held = rig.held(Kind::Group, A).await;
    let token = rig.token().await;
    let report = rig.fetch_through(&transport).await.unwrap();

    assert!(held.is_some_and(|row| row.record.fields.is_none()));
    assert!(token.is_some());
    assert!(rig.store(Kind::Group).fields(B).is_some());
    assert_eq!(report.counts.recovered, 1);
    assert_eq!(
        rig.store(Kind::Group).fields(A),
        Some(projected(Kind::Group, A, &json!({"name": A})))
    );
    assert!(rig.held(Kind::Group, A).await.is_none());
    assert_eq!(transport.names_asked().len(), 3);
}

#[tokio::test]
async fn a_read_by_name_cloudkit_finds_too_large_is_split_and_sent_again() {
    let rig = Rig::new().await;
    for id in [A, B, C] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    for id in [A, B, C] {
        rig.store(Kind::Group).make_unreadable(id);
        rig.save_elsewhere(Kind::Group, id, &json!({"name": "renamed"}));
    }
    rig.fetch().await.unwrap();
    for id in [A, B, C] {
        rig.store(Kind::Group)
            .put(id, projected(Kind::Group, id, &json!({"name": id})));
    }
    let transport = Unreliable::new(&rig.cloud);
    transport.limit_names(1);

    let report = rig.fetch_through(&transport).await.unwrap();

    let sizes: Vec<usize> = transport.names_asked().iter().map(Vec::len).collect();
    assert_eq!(sizes, [3, 1, 2, 1, 1]);
    assert_eq!(report.counts.recovered, 3);
    for id in [A, B, C] {
        assert_eq!(
            rig.store(Kind::Group).fields(id),
            Some(projected(Kind::Group, id, &json!({"name": "renamed"})))
        );
    }
}

#[tokio::test]
async fn a_change_to_an_unreadable_local_only_copy_is_not_held() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let kept = projected(Kind::Connection, A, &json!({"name": "on this Mac"}));
    rig.store(Kind::Connection).put_with(A, kept, Standing::LocalOnly);
    rig.save_elsewhere(Kind::Connection, B, &json!({"name": "loads the standing"}));
    rig.fetch().await.unwrap();
    rig.store(Kind::Connection).make_unreadable(A);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "renamed"}));

    let report = rig.fetch().await.unwrap();

    assert_eq!(report.counts.held, 0);
    assert!(rig.held(Kind::Connection, A).await.is_none());
}

// The zone lost the record with no deletion a delta carried: the held change no longer stands.
#[tokio::test]
async fn a_held_change_whose_record_the_zone_no_longer_holds_is_released() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.fetch().await.unwrap();
    rig.store(Kind::Group).make_unreadable(A);
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "renamed"}));
    rig.fetch().await.unwrap();
    rig.delete_elsewhere(Kind::Group, A);
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "a"})));
    let transport = Unreliable::new(&rig.cloud);
    transport.hide_deletions();

    rig.fetch_through(&transport).await.unwrap();

    assert!(rig.held(Kind::Group, A).await.is_none());
    assert_eq!(
        rig.store(Kind::Group).fields(A),
        Some(projected(Kind::Group, A, &json!({"name": "a"})))
    );
}

// A copy that came back but does not project reads no better on the next pass, so it is not asked for again.
#[tokio::test]
async fn a_copy_this_build_cannot_project_is_held_and_not_asked_for_on_every_pass() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    rig.cloud.save_elsewhere(
        USER,
        "Connection",
        &name(Kind::Connection, A),
        vec![CloudKitField {
            name: "port".to_owned(),
            value: Some(CloudKitValue::Text("not a port".to_owned())),
        }],
    );
    let transport = Unreliable::new(&rig.cloud);

    rig.fetch_through(&transport).await.unwrap();
    rig.fetch_through(&transport).await.unwrap();

    assert!(rig.held(Kind::Connection, A).await.is_some());
    assert!(transport.names_asked().iter().all(Vec::is_empty));
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(Kind::Connection, A, &json!({"name": "prod"})))
    );
}
