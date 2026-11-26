use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::merge::{Merged, Mode, Sides, merge};
use tablepro_records::record_id::favourite_table;
use tablepro_sync::api::cloudkit::{CloudKitOutcome, CloudKitRecord, CloudKitTransport};
use tablepro_sync::api::ids::ChangeTag;
use tablepro_sync::cloudkit::fetch::ServerChanged;

use crate::faults::Unreliable;
use crate::support::{A, B, Rig, USER, cloud_fields, name, projected};

fn cases() -> Vec<Value> {
    let cases: Value = serde_json::from_str(include_str!("../../../records/fixtures/merge.json")).unwrap();
    cases.as_array().unwrap().clone()
}

fn id_for(kind: Kind, case: &Value) -> String {
    match kind {
        Kind::FavouriteTable => favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id,
        Kind::MacosSettings => ["local", "base", "server"]
            .iter()
            .find_map(|side| case[side]["category"].as_str())
            .unwrap()
            .to_owned(),
        _ => A.to_owned(),
    }
}

// CloudKit keeps a member this build does not know on its own copy, so the projection does not carry it.
fn carries_unknown_members(case: &Value) -> bool {
    ["base", "server"]
        .iter()
        .any(|side| case[side].get("future").is_some() || case[side].get("from_a_newer_build").is_some())
}

fn side(kind: Kind, id: &str, case: &Value, name: &str) -> Option<Value> {
    let copy = &case[name];
    (!copy.is_null()).then(|| projected(kind, id, copy))
}

// The shared fixtures on the CloudKit path (0054, Verification): the base comes from a fetch, the store and the zone
// change, and the next fetch leaves the store holding what the field merge gives once the person approved what waited.
#[tokio::test]
async fn the_shared_merge_fixtures_land_in_the_store_through_a_fetch() {
    let cases = cases();
    let personal: Vec<&Value> = cases
        .iter()
        .filter(|case| case["mode"] == "personal" && !carries_unknown_members(case))
        .collect();
    assert!(personal.len() >= 10);
    for case in personal {
        let kind = tablepro_records::Kind::parse(case["kind"].as_str().unwrap())
            .unwrap()
            .unwrap();
        let id = id_for(kind, case);
        let (base, local, server) = (
            side(kind, &id, case, "base"),
            side(kind, &id, case, "local"),
            side(kind, &id, case, "server"),
        );
        let rig = Rig::new().await;
        if let Some(base) = &base {
            rig.save_elsewhere(kind, &id, base);
            rig.fetch().await.unwrap();
            rig.approve_everything().await;
        }
        match &local {
            Some(local) => rig.store(kind).put(&id, local.clone()),
            None => rig.store(kind).remove(&id),
        }
        match &server {
            Some(server) => rig.save_elsewhere(kind, &id, server),
            None => rig.delete_elsewhere(kind, &id),
        }

        rig.fetch().await.unwrap();
        rig.approve_everything().await;

        let label = case["name"].as_str().unwrap();
        let expected = merge(
            kind,
            Mode::Personal,
            Sides {
                base: base.as_ref(),
                local: local.as_ref(),
                server: server.as_ref(),
            },
        );
        assert_eq!(expected == Merged::Deleted, case["merged"] == "deleted", "{label}");
        match expected {
            Merged::Record(record) => assert_eq!(rig.store(kind).fields(&id), Some(record), "{label}"),
            Merged::Deleted => assert_eq!(rig.store(kind).fields(&id), None, "{label}"),
            other => panic!("{label}: {other:?}"),
        }
        let based = rig.base(kind, &id).await.and_then(|base| base.fields);
        assert_eq!(based, server, "{label}");
    }
}

async fn refused_save(rig: &Rig, id: &str, fields: &Value) -> CloudKitOutcome {
    let base = rig.base(Kind::Connection, id).await.unwrap();
    let ChangeTag::CloudKit(system_fields) = base.tag else {
        panic!("a CloudKit base");
    };
    let save = CloudKitRecord {
        record_type: "Connection".to_owned(),
        name: name(Kind::Connection, id),
        system_fields: Some(system_fields),
        created_ms: None,
        fields: cloud_fields(Kind::Connection, id, fields),
    };
    rig.cloud
        .modify(USER.to_owned(), vec![save], Vec::new())
        .await
        .unwrap()
        .remove(0)
}

async fn edited_on_both_sides() -> (Rig, Value) {
    let rig = Rig::new().await;
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "query_timeout_seconds": 30}),
    );
    rig.fetch().await.unwrap();
    let mine = projected(
        Kind::Connection,
        A,
        &json!({"name": "mine", "query_timeout_seconds": 30}),
    );
    rig.store(Kind::Connection).put(A, mine.clone());
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "query_timeout_seconds": 60}),
    );
    (rig, mine)
}

async fn saved_after_the_rebase(rig: &Rig) -> CloudKitOutcome {
    let merged = rig.store(Kind::Connection).fields(A).unwrap();
    refused_save(rig, A, &merged).await
}

#[tokio::test]
async fn a_save_refused_with_the_server_s_copy_merges_with_it_and_goes_through_on_its_tag() {
    let (rig, mine) = edited_on_both_sides().await;
    let CloudKitOutcome::ServerChanged { name, server } = refused_save(&rig, A, &mine).await else {
        panic!("not refused");
    };
    let server_tag = server.as_ref().and_then(|copy| copy.system_fields.clone()).unwrap();

    let rebased = rig.rebase(vec![ServerChanged { name, server }]).await.unwrap();

    let base = rig.base(Kind::Connection, A).await.unwrap();
    assert_eq!(rebased.merged.len(), 1);
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "mine", "query_timeout_seconds": 60})
        ))
    );
    assert_eq!(base.tag, ChangeTag::CloudKit(server_tag));
    assert!(matches!(
        saved_after_the_rebase(&rig).await,
        CloudKitOutcome::Saved { .. }
    ));
}

#[tokio::test]
async fn a_refusal_that_carries_no_copy_fetches_the_record_by_name() {
    let (rig, _) = edited_on_both_sides().await;

    let rebased = rig
        .rebase(vec![ServerChanged {
            name: name(Kind::Connection, A),
            server: None,
        }])
        .await
        .unwrap();

    assert_eq!(rebased.merged, [name(Kind::Connection, A)]);
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "mine", "query_timeout_seconds": 60})
        ))
    );
    assert!(matches!(
        saved_after_the_rebase(&rig).await,
        CloudKitOutcome::Saved { .. }
    ));
}

// D12: a record the zone lost meanwhile comes back only with a content edit, as a create with no base.
#[tokio::test]
async fn a_record_gone_from_the_zone_keeps_a_content_edit_and_drops_a_reorder() {
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
    let conflicts = [A, B].map(|id| ServerChanged {
        name: name(Kind::Connection, id),
        server: None,
    });

    let rebased = rig.rebase(conflicts.to_vec()).await.unwrap();

    assert_eq!(rebased.gone.len(), 2);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(renamed));
    assert!(rig.base(Kind::Connection, A).await.is_none());
    assert_eq!(rig.store(Kind::Connection).fields(B), None);
    assert!(rig.base(Kind::Connection, B).await.is_none());
}

#[tokio::test]
async fn a_refusal_whose_copy_names_another_record_is_not_merged() {
    let (rig, mine) = edited_on_both_sides().await;
    let other = rig.cloud.record(USER, &name(Kind::Connection, A)).map(|mut copy| {
        copy.name = name(Kind::Connection, B);
        copy
    });

    let rebased = rig
        .rebase(vec![ServerChanged {
            name: name(Kind::Connection, A),
            server: other,
        }])
        .await
        .unwrap();

    assert!(rebased.merged.is_empty());
    assert_eq!(rebased.failed.len(), 1);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(mine));
    assert!(!rig.store(Kind::Connection).holds(B));
}

// A deletion found late never removes a profile; its deletion comes through the changes.
#[tokio::test]
async fn a_profile_the_zone_lost_is_not_deleted_by_a_rebase() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::SshProfile, A, &json!({"name": "bastion", "host": "jump"}));
    rig.fetch().await.unwrap();
    rig.approve_everything().await;
    rig.delete_elsewhere(Kind::SshProfile, A);

    let rebased = rig
        .rebase(vec![ServerChanged {
            name: name(Kind::SshProfile, A),
            server: None,
        }])
        .await
        .unwrap();

    assert_eq!(rebased.gone, [name(Kind::SshProfile, A)]);
    assert!(rig.store(Kind::SshProfile).holds(A));
    assert!(rig.base(Kind::SshProfile, A).await.is_some());
}

#[tokio::test]
async fn a_refusal_whose_copy_cannot_be_read_waits_for_a_later_pass() {
    let (rig, mine) = edited_on_both_sides().await;
    let transport = Unreliable::new(&rig.cloud);
    transport.fail_reads(&name(Kind::Connection, A), 1);

    let rebased = rig
        .fetcher(&transport)
        .rebase(vec![ServerChanged {
            name: name(Kind::Connection, A),
            server: None,
        }])
        .await
        .unwrap();

    assert!(rebased.merged.is_empty());
    assert_eq!(rebased.failed[0].code, Some(15));
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(mine));
}
